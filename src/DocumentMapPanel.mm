#import "DocumentMapPanel.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import "ScintillaMessages.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"
#import "TabManager.h"
#import "SearchEngine.h"
#import "DocumentMapGeometry.h"
#import "../regex/NppRegexSearch.h"
#include <vector>

static const CGFloat kDMRulerWidth = 14;
static const size_t kDMMatchLimit = 19999;
static const size_t kDMRulerBuckets = 2048;
static const sptr_t kDMSearchWindow = 256 * 1024;
struct DMMatch {
    sptr_t start, end, line, endLine;
};

// The map shares the tracked editor's Scintilla document (SCI_SETDOCPOINTER),
// so it must never take keyboard focus: SCI_SETREADONLY is a document
// property, so the map cannot protect itself without making the editor
// read-only too. The viewport overlay already swallows mouse input; this
// content view keeps the map out of the key-view loop and menu targeting,
// and refuses drops: Scintilla's drop path ignores read-only, so a text drag
// from the editor onto the map would otherwise move text in the document.
// _configureMapSci also unregisters its drag types; these overrides are the
// backstop if anything registers them again.
@interface _DMMapContentView : SCIContentView
@end
@implementation _DMMapContentView
- (BOOL)acceptsFirstResponder { return NO; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationNone; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return NSDragOperationNone; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return NO; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { return NO; }
@end

@interface _DMMapScintillaView : ScintillaView
@end
@implementation _DMMapScintillaView
+ (Class)contentViewClass { return [_DMMapContentView class]; }
@end

// ─────────────────────────────────────────────────────────────────────────────
@class _DMViewportOverlay;

@interface DocumentMapPanel ()
- (NSRect)_viewportRectForOverlay:(_DMViewportOverlay *)overlay;
- (NSColor *)_viewportColor;
- (void)_overlayMouseDown:(NSPoint)pt;
- (void)_overlayMouseDragged:(NSPoint)pt;
- (void)_overlayScrollWheel:(NSEvent *)event;
- (void)_drawSearchMarks;
- (void)_scanSearchBatch;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface _DMViewportOverlay : NSView
@property (nonatomic, weak) DocumentMapPanel *panel;
@end

@implementation _DMViewportOverlay

- (BOOL)isOpaque                          { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e    { return YES; }
- (void)cursorUpdate:(NSEvent *)e         { [[NSCursor arrowCursor] set]; }

- (void)drawRect:(NSRect)dirty {
    NSRect vr = [self.panel _viewportRectForOverlay:self];
    if (!NSIsEmptyRect(vr)) {
        [[self.panel _viewportColor] setFill];
        [NSBezierPath fillRect:vr];
    }
    [self.panel _drawSearchMarks];
}

- (void)mouseDown:(NSEvent *)e {
    [self.panel _overlayMouseDown:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseDragged:(NSEvent *)e {
    [self.panel _overlayMouseDragged:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent *)e     { /* intentionally empty */ }
- (void)scrollWheel:(NSEvent *)e { [self.panel _overlayScrollWheel:e]; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 migration: title bar + close button + separator formerly owned
// by this file now live in PanelFrame (shared chrome). The panel body is
// just the map Scintilla + viewport overlay, mounted flush to edges.
// ─────────────────────────────────────────────────────────────────────────────

@implementation DocumentMapPanel {
    ScintillaView      *_mapSci;
    sptr_t              _mapDoc;       // document shared with _trackedEditor (0 = own empty doc)
    _DMViewportOverlay *_overlay;
    __weak EditorView  *_trackedEditor;
    NSTimer            *_contentDebounce;
    NSColor            *_viewportColor; // theme-derived; see -_applyChromeForBackground:
    CGFloat             _dragStartY, _dragTrackHeight;
    sptr_t              _dragStartFirst;
    BOOL                _draggingRuler;
    std::vector<DMMatch> _matches;
    std::vector<DMMatch> _rulerMatches;
    NPPFindOptions     *_searchOptions;
    NSData             *_searchNeedle;
    NSTimer            *_searchTimer;
    sptr_t              _searchPosition;
    BOOL                _searchFinished;
}

// ── Init / dealloc ────────────────────────────────────────────────────────────

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _buildLayout];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_cursorMoved:)
                   name:EditorViewCursorDidMoveNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_documentChanged:)
                   name:EditorViewDocumentDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_searchChanged:)
                   name:NPPOverviewSearchChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_prefsChanged:)
                   name:@"NPPPreferencesChanged" object:nil];
        // In Auto mode the dark-mode switch commits a new editor theme; in
        // forced Light/Dark it only changes the chrome. Either way re-derive.
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_prefsChanged:)
                   name:NPPDarkModeChangedNotification object:nil];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_contentDebounce invalidate];
    [_searchTimer invalidate];
}

// ── Layout ────────────────────────────────────────────────────────────────────

- (void)_buildLayout {
    _mapSci = [[_DMMapScintillaView alloc] initWithFrame:NSZeroRect];
    _mapSci.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_mapSci];
    [NSLayoutConstraint activateConstraints:@[
        [_mapSci.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_mapSci.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_mapSci.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kDMRulerWidth],
        [_mapSci.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [self _configureMapSci];

    // Files dropped on the map open like files dropped on the editor.
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    _overlay = [[_DMViewportOverlay alloc] initWithFrame:NSZeroRect];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.panel = self;
    [self addSubview:_overlay positioned:NSWindowAbove relativeTo:_mapSci];
    [NSLayoutConstraint activateConstraints:@[
        [_overlay.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_overlay.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_overlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_overlay.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (void)_configureMapSci {
    // Not a drop target for text (see _DMMapContentView). File drops are
    // taken by the panel itself and handed to the editor area.
    [_mapSci.content unregisterDraggedTypes];
    // No SCI_SETREADONLY: it would mark the shared document read-only.
    [_mapSci message:SCI_SETMODEVENTMASK     wParam:0];
    for (int m = 0; m < 5; m++)
        [_mapSci message:SCI_SETMARGINWIDTHN wParam:(uptr_t)m lParam:0];
    [_mapSci message:SCI_SETCARETLINEVISIBLE wParam:0];
    [_mapSci message:SCI_SETCARETWIDTH       wParam:0];
    [_mapSci message:SCI_SETHSCROLLBAR       wParam:0];
    [_mapSci message:SCI_SETVSCROLLBAR       wParam:0];
    [_mapSci message:SCI_SETWRAPMODE         wParam:SC_WRAP_NONE];
    [_mapSci message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:400]; // 4pt
    [_mapSci message:SCI_STYLECLEARALL];
    // Indicators live in the shared document; hide them so the editor's
    // find marks, smart highlights and spell-check squiggles do not render
    // with Scintilla's default indicator styles in the map.
    for (int i = 0; i <= INDICATOR_MAX; i++)
        [_mapSci message:SCI_INDICSETSTYLE wParam:(uptr_t)i lParam:INDIC_HIDDEN];
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)setTrackedEditor:(EditorView *)editor {
    _trackedEditor = editor;
    [self _updateMapContent];
}

// Informal hook called by MainWindowController on every hide path (title-bar
// close, toolbar/menu toggle, plugin hide). A hidden map is not re-targeted
// on tab switches, so drop the shared document now rather than keep a closed
// tab's document alive. Reopening calls -setTrackedEditor: again.
- (void)panelWillClose {
    [self setTrackedEditor:nil];
}

// ── File drops ────────────────────────────────────────────────────────────────
//
// The editor area's NppDropView opens dropped files; it is not an ancestor of
// the side panel, so forward to the one that hosts the tracked editor.

- (nullable NppDropView *)_editorDropView {
    for (NSView *v = _trackedEditor.superview; v; v = v.superview)
        if ([v isKindOfClass:[NppDropView class]]) return (NppDropView *)v;
    return nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NppDropView *dv = [self _editorDropView];
    return dv ? [dv draggingEntered:sender] : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    return [[self _editorDropView] performDragOperation:sender];
}

// ── Content update (debounced) ────────────────────────────────────────────────

- (void)_scheduleContentUpdate {
    [_contentDebounce invalidate];
    _contentDebounce = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                        target:self
                                                      selector:@selector(_updateMapContent)
                                                      userInfo:nil
                                                       repeats:NO];
}

// The map views the editor's own document, so text, lexer state, keyword
// lists and style bytes all come from the editor's lexing; nothing is copied.
// This only re-attaches when the editor swapped documents (file load/reload
// creates a fresh document) and refreshes the per-view style colours.
- (void)_updateMapContent {
    sptr_t previousDoc = _mapDoc;
    [self _syncDocument];
    [self _applyThemeFromEditor:_trackedEditor];
    [self _syncScroll];
    [_overlay setNeedsDisplay:YES];
    if (previousDoc != _mapDoc) [self _restartSearch];
}

- (void)_syncDocument {
    EditorView *ed = _trackedEditor;
    sptr_t doc = ed ? [ed.scintillaView message:SCI_GETDOCPOINTER] : 0;
    if (doc == _mapDoc) return;
    // SCI_SETDOCPOINTER adds a reference to the new document and releases
    // the old one; 0 gives the map a fresh empty document of its own.
    [_mapSci message:SCI_SETDOCPOINTER wParam:0 lParam:doc];
    _mapDoc = doc;
}

// ── Theme mirroring ───────────────────────────────────────────────────────────

// Scintilla colours are 0xBBGGRR.
static NSColor *_dmColorFromBGR(sptr_t bgr) {
    return [NSColor colorWithSRGBRed:(bgr & 0xFF) / 255.0
                               green:((bgr >> 8) & 0xFF) / 255.0
                                blue:((bgr >> 16) & 0xFF) / 255.0
                               alpha:1.0];
}

static sptr_t _dmBGRFromColor(NSColor *c) {
    NSColor *rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return 0;
    return (sptr_t)lround(rgb.redComponent * 255)
         | ((sptr_t)lround(rgb.greenComponent * 255) << 8)
         | ((sptr_t)lround(rgb.blueComponent * 255) << 16);
}

- (void)_applyThemeFromEditor:(nullable EditorView *)ed {
    ScintillaView *src = ed.scintillaView;
    if (!src) {
        // No editor to mirror: paint the empty map with the theme instead of
        // Scintilla's built-in white, which glares under a dark theme.
        NPPStyleStore *store = [NPPStyleStore sharedStore];
        sptr_t bg = _dmBGRFromColor(store.globalBg);
        [_mapSci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:_dmBGRFromColor(store.globalFg)];
        [_mapSci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:bg];
        [self _applyChromeForBackground:_dmColorFromBGR(bg)];
        return;
    }
    sptr_t defaultFg = [src message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT];
    sptr_t defaultBg = [src message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
    [_mapSci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:defaultFg];
    [_mapSci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:defaultBg];
    [self _applyChromeForBackground:_dmColorFromBGR(defaultBg)];
    // 0-255 so lexer substyles (e.g. LexCPP 128+, LexHTML 192+) are mirrored too.
    for (int s = 0; s < 256; s++) {
        sptr_t fg = [src message:SCI_STYLEGETFORE wParam:(uptr_t)s];
        [_mapSci message:SCI_STYLESETFORE wParam:(uptr_t)s lParam:fg];
        [_mapSci message:SCI_STYLESETBACK wParam:(uptr_t)s lParam:defaultBg];
        [_mapSci message:SCI_STYLESETBOLD wParam:(uptr_t)s
                  lParam:[src message:SCI_STYLEGETBOLD wParam:(uptr_t)s]];
        [_mapSci message:SCI_STYLESETITALIC wParam:(uptr_t)s
                  lParam:[src message:SCI_STYLEGETITALIC wParam:(uptr_t)s]];
    }
}

// The map body is painted with the editor theme, which need not match the
// chrome (dark title bar over a light theme, or the reverse). Key the native
// appearance and the viewport highlight off that background, not -isDark.
- (void)_applyChromeForBackground:(NSColor *)bg {
    _mapSci.appearance = [NppThemeManager appearanceForBackground:bg];
    NSColor *focus = [[NPPStyleStore sharedStore] globalStyleNamed:@"Document map"].fgColor;
    _viewportColor = [[NppThemeManager shared] documentMapViewportColorOnBackground:bg
                                                                         themeColor:focus];
    [_overlay setNeedsDisplay:YES];
}

- (NSColor *)_viewportColor {
    if (!_viewportColor) [self _applyThemeFromEditor:_trackedEditor];
    return _viewportColor;
}

// ── Viewport and scrolling ──────────────────────────────────────────────────

- (sptr_t)_totalDisplayLines {
    ScintillaView *src = _trackedEditor.scintillaView;
    sptr_t last = MAX((sptr_t)0, [src message:SCI_GETLINECOUNT] - 1);
    sptr_t lastHeight = [src message:SCI_GETLINEVISIBLE wParam:last] ?
        [src message:SCI_WRAPCOUNT wParam:last] : 0;
    return MAX((sptr_t)1, [src message:SCI_VISIBLEFROMDOCLINE wParam:last] + lastHeight);
}

- (sptr_t)_maxFirstDisplayLine {
    return MAX((sptr_t)0, [self _totalDisplayLines] -
               MAX((sptr_t)1, [_trackedEditor.scintillaView message:SCI_LINESONSCREEN]));
}

- (DocumentMap::Viewport)_mapViewport {
    ScintillaView *src = _trackedEditor.scintillaView;
    sptr_t first = [src message:SCI_GETFIRSTVISIBLELINE];
    sptr_t visible = MAX((sptr_t)1, [src message:SCI_LINESONSCREEN]);
    sptr_t firstDoc = [src message:SCI_DOCLINEFROMVISIBLE wParam:first];
    sptr_t lastDoc = [src message:SCI_DOCLINEFROMVISIBLE
                          wParam:MIN([self _totalDisplayLines] - 1, first + visible - 1)];
    sptr_t maxFirst = [self _maxFirstDisplayLine];
    return DocumentMap::viewport([src message:SCI_GETLINECOUNT], firstDoc, lastDoc + 1,
        maxFirst ? (double)first / maxFirst : 0,
        MAX((sptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]), _overlay.bounds.size.height);
}

- (void)_syncScroll {
    if (!_trackedEditor) return;
    auto viewport = [self _mapViewport];
    if ([_mapSci message:SCI_GETFIRSTVISIBLELINE] != viewport.firstMapLine)
        [_mapSci message:SCI_SETFIRSTVISIBLELINE wParam:viewport.firstMapLine];
    [_overlay setNeedsDisplay:YES];
}

- (void)layout {
    [super layout];
    [self _syncScroll];
}

- (NSRect)_viewportRectForOverlay:(_DMViewportOverlay *)overlay {
    if (!_trackedEditor) return NSZeroRect;
    auto viewport = [self _mapViewport];
    return NSMakeRect(0, overlay.bounds.size.height - viewport.top - viewport.height,
                      MAX(0, overlay.bounds.size.width - kDMRulerWidth), viewport.height);
}

// ── Live search (the map has independent search targets on the shared document) ──

- (void)_restartSearch {
    [_searchTimer invalidate];
    _searchTimer = nil;
    _matches.clear();
    _rulerMatches.assign(kDMRulerBuckets, {-1, -1, -1, -1});
    _searchPosition = 0;
    _searchFinished = NO;
    _searchOptions = [SearchEngine overviewSearchOptions];
    [_overlay setNeedsDisplay:YES];
    if (!_trackedEditor || !_searchOptions.searchText.length) return;
    NSString *needle = _searchOptions.searchType == NPPSearchExtended
        ? [SearchEngine expandExtendedString:_searchOptions.searchText] : _searchOptions.searchText;
    _searchNeedle = [needle dataUsingEncoding:NSUTF8StringEncoding];
    if (!_searchNeedle.length) return;
    int flags = [SearchEngine scintillaFlagsForOptions:_searchOptions];
    if (_searchOptions.searchType == NPPSearchRegex)
        flags |= SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;
    [_mapSci message:SCI_SETSEARCHFLAGS wParam:flags];
    __weak typeof(self) weakSelf = self;
    _searchTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
        [weakSelf _scanSearchBatch];
    }];
    // Coalesce typing and edits; subsequent batches yield to the event loop.
    _searchTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.15];
}

- (void)_scanSearchBatch {
    sptr_t length = [_mapSci message:SCI_GETLENGTH];
    sptr_t totalLines = MAX((sptr_t)1, [_mapSci message:SCI_GETLINECOUNT]);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.006;
    int count = 0;
    while (!_searchFinished && count++ < 200 && CFAbsoluteTimeGetCurrent() < deadline) {
        // Literal searches use bounded targets. Regex keeps the full target:
        // an arbitrary multiline expression has no safe fixed overlap.
        sptr_t window = _searchOptions.searchType == NPPSearchRegex ? length :
            MAX(kDMSearchWindow, (sptr_t)_searchNeedle.length * 2 + 16);
        sptr_t endOfWindow = MIN(length, _searchPosition + window);
        [_mapSci message:SCI_SETTARGETRANGE wParam:_searchPosition lParam:endOfWindow];
        sptr_t found = [_mapSci message:SCI_SEARCHINTARGET wParam:_searchNeedle.length
                                lParam:(sptr_t)_searchNeedle.bytes];
        if (found < 0) {
            if (endOfWindow == length) { _searchFinished = YES; break; }
            sptr_t overlap = MIN(window / 2, (sptr_t)_searchNeedle.length + 8);
            _searchPosition = endOfWindow - overlap;
            continue;
        }
        sptr_t end = [_mapSci message:SCI_GETTARGETEND];
        DMMatch match = {found, end,
            [_mapSci message:SCI_LINEFROMPOSITION wParam:found],
            [_mapSci message:SCI_LINEFROMPOSITION wParam:MAX(found, end - 1)]};
        if (_matches.size() < kDMMatchLimit) _matches.push_back(match);
        size_t bucket = MIN(kDMRulerBuckets - 1,
            (size_t)((double)match.line / totalLines * kDMRulerBuckets));
        if (_rulerMatches[bucket].start < 0) _rulerMatches[bucket] = match;
        if (end > found) _searchPosition = end;
        else if (found < length) _searchPosition = [_mapSci message:SCI_POSITIONAFTER wParam:found];
        else _searchFinished = YES;
        // Once precise highlights are full, one result per ruler bucket is
        // sufficient. Skip the rest of a dense bucket instead of visiting
        // millions of identical hits on the main thread.
        if (_matches.size() == kDMMatchLimit) {
            if (bucket + 1 == kDMRulerBuckets) _searchFinished = YES;
            else {
                sptr_t nextLine = (sptr_t)ceil((double)(bucket + 1) * totalLines / kDMRulerBuckets);
                sptr_t nextPosition = [_mapSci message:SCI_POSITIONFROMLINE wParam:nextLine];
                if (nextPosition > _searchPosition) _searchPosition = nextPosition;
            }
        }
    }
    if (_searchFinished) { [_searchTimer invalidate]; _searchTimer = nil; }
    [_overlay setNeedsDisplay:YES];
}

- (BOOL)_isCurrentMatch:(const DMMatch &)match {
    ScintillaView *src = _trackedEditor.scintillaView;
    return [src message:SCI_GETSELECTIONSTART] == match.start &&
           [src message:SCI_GETSELECTIONEND] == match.end;
}

- (NSRect)_rulerThumbRect {
    CGFloat height = _overlay.bounds.size.height;
    ScintillaView *src = _trackedEditor.scintillaView;
    CGFloat thumbH = MIN(height, MAX(18.0, height * [src message:SCI_LINESONSCREEN] /
                                   MAX((sptr_t)1, [self _totalDisplayLines])));
    CGFloat progress = [self _maxFirstDisplayLine] ?
        (CGFloat)[src message:SCI_GETFIRSTVISIBLELINE] / [self _maxFirstDisplayLine] : 0;
    return NSMakeRect(_overlay.bounds.size.width - kDMRulerWidth,
        (height - thumbH) * (1 - MIN(1.0, progress)), kDMRulerWidth, thumbH);
}

- (void)_drawSearchMarks {
    CGFloat height = _overlay.bounds.size.height;
    CGFloat width = _overlay.bounds.size.width;
    if (height <= 0 || width <= kDMRulerWidth) return;
    CGFloat rulerX = width - kDMRulerWidth;
    NSColor *bg = _dmColorFromBGR([_mapSci message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT]);
    [bg setFill];
    NSRectFill(NSMakeRect(rulerX, 0, kDMRulerWidth, height));
    if (!_trackedEditor) return;

    // A separate full-document track stays useful when only part of a long map fits.
    ScintillaView *src = _trackedEditor.scintillaView;
    sptr_t total = MAX((sptr_t)1, [src message:SCI_GETLINECOUNT]);
    [[self _viewportColor] setFill];
    NSRectFill([self _rulerThumbRect]);

    NSColor *matchColor = [NSColor systemTealColor];
    NSColor *currentColor = [NSColor systemOrangeColor];
    // Full-file marks stay bounded independently of the number of matches.
    [matchColor setFill];
    for (const DMMatch &match : _rulerMatches) {
        if (match.start >= 0)
            NSRectFill(NSMakeRect(rulerX + 3,
                MAX(0, height - 2 - (CGFloat)match.line / total * height),
                kDMRulerWidth - 6, 2));
    }

    sptr_t selection = [src message:SCI_GETSELECTIONSTART];
    auto current = std::lower_bound(_matches.begin(), _matches.end(), selection,
        [](const DMMatch &m, sptr_t position) { return m.start < position; });
    if (current != _matches.end() && [self _isCurrentMatch:*current]) {
        [currentColor setFill];
        NSRectFill(NSMakeRect(rulerX + 1, MAX(0, height - 2 - (CGFloat)current->line / total * height),
                              kDMRulerWidth - 2, 3));
    }

    // The visible map also highlights the actual matched text, including multi-line matches.
    sptr_t mapFirst = [_mapSci message:SCI_GETFIRSTVISIBLELINE];
    CGFloat lineH = MAX((sptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]);
    sptr_t mapLast = mapFirst + (sptr_t)ceil(height / lineH);
    auto it = std::lower_bound(_matches.begin(), _matches.end(), mapFirst,
        [](const DMMatch &m, sptr_t line) { return m.endLine < line; });
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(0, 0, rulerX, height));
    for (; it != _matches.end() && it->line <= mapLast; ++it) {
        BOOL currentMatch = [self _isCurrentMatch:*it];
        [[(currentMatch ? currentColor : matchColor) colorWithAlphaComponent:0.55] setFill];
        for (sptr_t line = MAX(mapFirst, it->line); line <= MIN(mapLast, it->endLine); ++line) {
            sptr_t start = line == it->line ? it->start :
                [_mapSci message:SCI_POSITIONFROMLINE wParam:line];
            sptr_t end = line == it->endLine ? it->end :
                [_mapSci message:SCI_GETLINEENDPOSITION wParam:line];
            CGFloat x1 = [_mapSci message:SCI_POINTXFROMPOSITION wParam:0 lParam:start];
            CGFloat x2 = [_mapSci message:SCI_POINTXFROMPOSITION wParam:0 lParam:end];
            NSRectFill(NSMakeRect(x1, height - (line - mapFirst + 1) * lineH,
                                  MAX(3.0, x2 - x1), lineH));
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}

// ── Mouse handling ──────────────────────────────────────────────────────────

- (void)_overlayMouseDown:(NSPoint)pt {
    if (!_trackedEditor) return;
    ScintillaView *src = _trackedEditor.scintillaView;
    CGFloat height = _overlay.bounds.size.height;
    CGFloat fromTop = height - pt.y;
    _draggingRuler = pt.x >= _overlay.bounds.size.width - kDMRulerWidth;
    NSRect viewport = [self _viewportRectForOverlay:_overlay];
    if (_draggingRuler) {
        sptr_t total = MAX((sptr_t)1, [src message:SCI_GETLINECOUNT]);
        double line = fromTop / MAX(1.0, height) * total;
        const DMMatch *nearest = nullptr;
        for (const DMMatch &match : _rulerMatches)
            if (match.start >= 0 && (!nearest || fabs(match.line - line) < fabs(nearest->line - line)))
                nearest = &match;
        if (nearest && fabs(nearest->line - line) * height / total <= 4) {
            [src message:SCI_ENSUREVISIBLE wParam:nearest->line];
            [src message:SCI_ENSUREVISIBLE wParam:nearest->endLine];
            [src message:SCI_SETSEL wParam:nearest->start lParam:nearest->end];
            [src message:SCI_SCROLLCARET];
        } else if (!NSPointInRect(pt, [self _rulerThumbRect])) {
            CGFloat thumbHeight = [self _rulerThumbRect].size.height;
            [src message:SCI_SETFIRSTVISIBLELINE
                  wParam:(uptr_t)std::clamp((sptr_t)lround((fromTop - thumbHeight / 2) /
                                                        MAX(1.0, height - thumbHeight) *
                                                        [self _maxFirstDisplayLine]),
                                            (sptr_t)0, [self _maxFirstDisplayLine])];
        }
    } else if (!NSPointInRect(pt, viewport)) {
        // Clicking code navigates to that code, rather than a percentage of the file.
        sptr_t lineH = MAX((sptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]);
        sptr_t line = [_mapSci message:SCI_GETFIRSTVISIBLELINE] + (sptr_t)(fromTop / lineH);
        line = std::clamp(line, (sptr_t)0, MAX((sptr_t)0, [src message:SCI_GETLINECOUNT] - 1));
        sptr_t visibleLine = [src message:SCI_VISIBLEFROMDOCLINE wParam:line];
        [src message:SCI_SETFIRSTVISIBLELINE
              wParam:MAX((sptr_t)0, visibleLine - [src message:SCI_LINESONSCREEN] / 2)];
    }
    [self _syncScroll];
    _dragStartY = fromTop;
    _dragStartFirst = [src message:SCI_GETFIRSTVISIBLELINE];
    CGFloat thumbHeight = _draggingRuler ? [self _rulerThumbRect].size.height :
        [self _viewportRectForOverlay:_overlay].size.height;
    _dragTrackHeight = height > thumbHeight ? height - thumbHeight : height;
}

- (void)_overlayMouseDragged:(NSPoint)pt {
    if (!_trackedEditor) return;
    sptr_t first = DocumentMap::draggedFirstLine(_dragStartFirst,
        _overlay.bounds.size.height - pt.y - _dragStartY,
        _dragTrackHeight, [self _maxFirstDisplayLine]);
    [_trackedEditor.scintillaView message:SCI_SETFIRSTVISIBLELINE wParam:first];
    [self _syncScroll];
}

- (void)_overlayScrollWheel:(NSEvent *)event {
    [_trackedEditor.scintillaView scrollWheel:event];
}

// ── Notifications ─────────────────────────────────────────────────────────────

- (void)_cursorMoved:(NSNotification *)note {
    if (note.object != _trackedEditor) return;
    sptr_t previousDoc = _mapDoc;
    [self _syncDocument];
    [self _syncScroll];
    if (previousDoc != _mapDoc) [self _restartSearch];
}

- (void)_documentChanged:(NSNotification *)note {
    EditorView *editor = note.object;
    if (!_trackedEditor || [editor.scintillaView message:SCI_GETDOCPOINTER] != _mapDoc) return;
    [self _restartSearch];
    [self _scheduleContentUpdate];
}

- (void)_searchChanged:(NSNotification *)note { [self _restartSearch]; }

- (void)_prefsChanged:(NSNotification *)note {
    // Both notifications are posted synchronously and every EditorView
    // re-applies its theme from its own observer. Observers run in
    // registration order, so an editor opened after the map would still hold
    // the old theme here and the map would copy stale colours. Read the
    // editor once the current notification has been delivered to everyone.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _applyThemeFromEditor:self->_trackedEditor];
    });
}


@end
