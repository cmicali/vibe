//
//  TagLibAudioFile.h
//  Vibe
//
//  The TagLib side of the metadata parse: the file factory, the format name
//  and the embedded-art read. C++, so only .mm files import it.
//

#import <Foundation/Foundation.h>
#import "AudioFileFormat.h"
#import "AudioTrackArtworkInternal.h"

#include <memory>
#include <tfile.h>
#include <tiostream.h>
#include <tag.h>

NS_ASSUME_NONNULL_BEGIN

// Replaces TagLib::FileRef, whose detection links every parser in the
// library. Same order: extension, isValid(), then magic bytes. Without
// readProperties no audio properties are parsed, which the art read never
// uses; no format's validity depends on them.
class TagLibAudioFile {
public:
    explicit TagLibAudioFile(const char *path, bool readProperties = true);

    bool isNull() const { return _file == nullptr; }
    TagLib::File *_Nullable file() const { return _file.get(); }
    TagLib::Tag *_Nullable tag() const { return _file ? _file->tag() : nullptr; }

private:
    static bool isOgg(TagLib::IOStream *stream);
    static std::unique_ptr<TagLib::File> openByExtension(const char *path, TagLib::IOStream *stream,
                                                         bool readProperties);
    static std::unique_ptr<TagLib::File> openByContent(TagLib::IOStream *stream, bool readProperties);

    std::unique_ptr<TagLib::IOStream> _stream; // declared first: must outlive _file
    std::unique_ptr<TagLib::File> _file;
};

VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file);
NSData *_Nullable albumArtDataFromTagLibFile(TagLib::File *file);

// A blocking read, called without the artwork monitor held. TagLib stays here
// so AudioTrackArtwork compiles as plain ObjC.
AudioTrackArtworkExtractor VibeTagLibArtExtractor(void);

// Routes TagLib's debug output to the log. Defined only where NDEBUG is not,
// since Release's TagLib::debug() is a no-op.
void VibeInstallTagLibDebugListener(void);

NS_ASSUME_NONNULL_END
