//
//  MainWindowLayout.h
//  Vibe
//
// Shared by MainWindow's sizing and MainPlayerContentView's design-time layout
// so the two cannot drift; ArtworkImageView reads the exclusion band.

#import <Foundation/Foundation.h>

// The body's design and first-launch width, pitch panel excluded.
static const CGFloat kMainWindowContentWidth = 680;

// Narrower, the codec and BPM readouts crowd the title.
static const CGFloat kMainWindowMinContentWidth = 480;

// The wide end of View > Width.
static const CGFloat kMainWindowLargeContentWidth = kMainWindowContentWidth * 1.75;

// Collapsed. Anything taller means the playlist is showing.
static const CGFloat kMainWindowSmallHeight = 150;

// What the playlist toggle opens to.
static const CGFloat kMainWindowLargeHeight = 400;

// Under this the pane is a sliver: the drop well loses room for its text, then
// vanishes at PlaylistDropZoneView's visibility floor.
static const CGFloat kPlaylistPaneMinHeight = 100;

// No height between kMainWindowSmallHeight and this is a resting height.
static const CGFloat kMainWindowMinLargeHeight = kMainWindowSmallHeight + kPlaylistPaneMinHeight;

// The design-time height every MainPlayerContentView frame is authored at.
static const CGFloat kMainWindowDesignHeight = 350;

// The band at the art's bottom edge where the transport buttons sit, so a
// mouse-down there must not start the art's drag-out.
static const CGFloat kArtworkTransportExclusionHeight = 42;
