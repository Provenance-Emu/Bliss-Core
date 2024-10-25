/*
 Copyright (c) 2014, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "BlissGameCoreBridge.h"

@import PVEmulatorCore;
@import PVCoreBridge;
@import PVCoreObjCBridge;
@import PVLoggingObjC;
@import PVAudio;

#if __has_include(<OpenGL/OpenGL.h>)
#import <OpenGL/gl3.h>
#import <OpenGL/gl3ext.h>
#import <OpenGL/OpenGL.h>
#import <GLUT/GLUT.h>
#else
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#endif

#if __has_include(<UIKit/UIKeyConstants.h>)
#import <UIKit/UIKeyConstants.h>
#endif

@import libbliss;
#import "core/Emulator.h"
#import "core/rip/Rip.h"
#import "core/audio/AudioMixer.h"
#import "core/video/VideoBus.h"
#import "drivers/intv/Intellivision.h"
#import "drivers/intv/HandController.h"
#import "drivers/intv/ECSKeyboard.h"

#define INTV_IMAGE_WIDTH	(160)
#define INTV_IMAGE_HEIGHT	(192)

#define A5200_IMAGE_WIDTH    (336)
#define A5200_IMAGE_HEIGHT    (240)

#define KEYBOARD_OBJECT_COUNT 256
#define AUDIO_SAMPLE_RATE 48000

#define INTY_TO_BITMAP(bits)  (1ULL << (uint64_t)(bits))

#define INTY_TEST(bits, flag) ((bits) &   (uint64_t)(flag))
#define INTY_ON(bits, flag)   ((bits) |=  (uint64_t)(flag))
#define INTY_OFF(bits, flag)  ((bits) &= ~(uint64_t)(flag))

#define GET_CURRENT_OR_RETURN(...) __strong __typeof__(_current) current = _current; if(current == nil) return __VA_ARGS__;

typedef struct {
	UINT16	keypad;
	UINT16	action;
	UINT16	disc;
} BlissController;

class BlissInputProducer : public InputProducer {
public:
	BlissInputProducer();

	const CHAR* getName() { return "Bliss Input"; }
	void poll() {}
	INT32 getInputCount() { return 23; }
	const CHAR* getInputName(INT32) { return "Bliss Input Name"; }

	float getValue(INT32 enumeration);

	BOOL isKeyboardDevice() { return keyboardDevice; }
	void setKeyboardDevice(BOOL isKeyboardDevice) {
		keyboardDevice = isKeyboardDevice;
	}

    //i think the core uses ints not chars
	void setPlayer(int playerIndex) {
		player = playerIndex;
	}

private:
	int player;
	BOOL keyboardDevice;
};

class BlissAudioMixer : public AudioMixer {
public:
	void		init(UINT32 sampleRate);
	void		release();
	void		flushAudio();
};

class BlissVideoBus : public VideoBus {
public:
	void		init(UINT32 width, UINT32 height);
	void		release();
	void		render();
};

@interface PVBlissGameCoreBridge () <PVIntellivisionSystemResponderClient> {
	NSLock			    *_bufferLock;
    id<RingBufferProtocol> _audioBuffer;
	unsigned char	    *_videoBuffer;
	BlissAudioMixer	*_audioMixer;
	BlissVideoBus	    *_videoBus;

    NSString		    *_ROMName;
	Emulator		    *currentEmu;
	Rip				    *currentRip;

	NSMutableData	    *_stateData;

    UINT32 targetSystemID;

    dispatch_queue_t audioQueue;
}
- (int)blissButtonForIntellivisionButton:(PVIntellivisionButton)button player:(NSUInteger)player;
@end

__weak PVBlissGameCoreBridge *_current;

@implementation PVBlissGameCoreBridge

// Global variables because the callbacks need to access them...
static BlissController _controller[2] = {0};
static uint64_t _keyboard = 0;
static uint8_t _keyboardDownCount = 0;
static uint8_t _keyboardShiftCount = 0;

#pragma mark - OpenEmu Core

/*
 OpenEmu Core internal functions
 */

- (instancetype)init {
    self = [super init];
    if(self != nil) {
        _bufferLock = [[NSLock alloc] init];

		_current = self;

		_audioMixer = new BlissAudioMixer;
		_videoBus = new BlissVideoBus;

		_stateData = [NSMutableData dataWithLength:sizeof(IntellivisionState)];

        dispatch_queue_attr_t priorityAttribute = dispatch_queue_attr_make_with_qos_class( DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        audioQueue = dispatch_queue_create("com.provenance.intellivision.audio", priorityAttribute);
    }

    return self;
}

- (void)dealloc {
    VLOG(@"releasing/deallocating Bliss memory");

	delete _videoBus;
	_videoBus = NULL;
	delete _audioMixer;
	_audioMixer = NULL;

	_current = NULL;
}

- (void)executeFrame {
    //DLOG(@"Executing");

	// run the emulation
	currentEmu->Run();

	// render and display the video
	currentEmu->Render();

	// flush the audio
	currentEmu->FlushAudio();
}

#pragma mark - Bliss Core Helpers

- (BOOL)LoadRip:(const char*)filename error:(NSError **)outError  {
	char cfgFilename[PATH_MAX] = {0};


    NSString *cfgString = self.knownCartsPath;
    if (!cfgString) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        cfgString = [bundle pathForResource:@"knowncarts"
                                               ofType:@"cfg"];
        if (!cfgString) {
            cfgString = [NSBundle.mainBundle pathForResource:@"knowncarts"
                                                      ofType:@"cfg"];
        }
    }

    if (cfgString == nil || cfgString.length < 5) {
        ELOG(@"Required file `knowncarts.cfg` not found");
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Failed to load `knowncarts.cfg`.",
            NSLocalizedFailureReasonErrorKey: cfgString == nil ? @"Path was nil" : @"Path was invalid",
            NSLocalizedRecoverySuggestionErrorKey: @"File a bug report."
        };
        *outError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                userInfo:userInfo];
        return false;
    }
	strncpy(cfgFilename, cfgString.fileSystemRepresentation, sizeof(cfgFilename));

    if(!cfgFilename[0]) {
        ELOG(@"cfgFilename is empty");
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Failed to load `knowncarts.cfg`.",
            NSLocalizedFailureReasonErrorKey: @"Path was empty",
            NSLocalizedRecoverySuggestionErrorKey: @"File a bug report."
        };
        *outError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                userInfo:userInfo];
        return FALSE;
    }

    if(strlen(filename) < 5) {
        ELOG(@"filename < 5");
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Failed to load `knowncarts.cfg`.",
            NSLocalizedFailureReasonErrorKey: @"Path was invalid",
            NSLocalizedRecoverySuggestionErrorKey: @"File a bug report."
        };
        *outError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                userInfo:userInfo];
        return FALSE;
    }

	const CHAR* extStart = filename + strlen(filename) - 4;
	if(strcmpi(extStart, ".intv") == 0 || strcmpi(extStart, ".int") == 0 || strcmpi(extStart, ".bin") == 0)
	{
		//load the bin file as a Rip
		currentRip = Rip::LoadBin(filename, cfgFilename);
        if(currentRip == NULL) {
            ELOG(@"LoadBin(%s) failed", filename);
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Failed to load ROM as a Intellivision ROM.",
                NSLocalizedFailureReasonErrorKey: @"ROM failed to load as a RIP",
                NSLocalizedRecoverySuggestionErrorKey: @"Try a different ROM."
            };
            *outError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                        code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                    userInfo:userInfo];
            return FALSE;
        }
	}
	else if(strcmpi(extStart, ".a52") == 0)
	{
		//load the bin file as a Rip
		currentRip = Rip::LoadA52(filename);
        if(currentRip == NULL) {
            ELOG(@"LoadA52(%s) failed", filename);
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Failed to load ROM as a A5200 ROM.",
                NSLocalizedFailureReasonErrorKey: @"ROM failed to load as a RIP",
                NSLocalizedRecoverySuggestionErrorKey: @"Try a different ROM."
            };
            *outError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                        code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                    userInfo:userInfo];
            return FALSE;
        }

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else if(strcmpi(extStart, ".irom") == 0 || strcmpi(extStart, ".rom") == 0)
	{
		//load the rom file as a Rip
		currentRip = Rip::LoadRom(filename);
        if(currentRip == NULL) {
            ELOG(@"LoadRom(%s) failed", filename);
            return FALSE;
        }

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else if(strcmpi(extStart, ".zip") == 0)
	{
		//load the zip file as a Rip
		currentRip = Rip::LoadZip(filename, cfgFilename);
        if(currentRip == NULL) {
            ELOG(@"LoadZip(%s) failed", filename);
            return FALSE;
        }

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else
	{
		//load the designated Rip
		currentRip = Rip::LoadRip(filename);
        if(currentRip == NULL) {
            ELOG(@"LoadRip(%s) failed", filename);
            return FALSE;
        }
	}

	return TRUE;
}

- (BOOL)loadROMForPeripheral:(Peripheral*)peripheral {
	BOOL didLoadROMs = NO;
	NSString *BIOSPath = nil;
	UINT16 count = peripheral->GetROMCount();

	for(UINT16 i = 0; i < count; i++) {
		ROM* r = peripheral->GetROM(i);
		if(r->isLoaded()){
			didLoadROMs = YES;
			continue;
		}

		BIOSPath = [[self BIOSPath] stringByAppendingString:[NSString stringWithFormat:@"/%s", r->getDefaultFileName()]];

        ILOG(@"Attempting to load BIOS at `%@`", BIOSPath);

		if(r->load([BIOSPath fileSystemRepresentation], r->getDefaultFileOffset())){
			didLoadROMs = YES;
		} else {
			didLoadROMs = NO;
			break;
		}
	}

	return didLoadROMs;
}

- (void)ReleasePeripheralInputs:(Peripheral*)periph {
	UINT16 count = periph->GetInputConsumerCount();

	for(UINT16 i = 0; i < count; i++) {
		InputConsumer* nextInputConsumer = periph->GetInputConsumer(i);

		//iterate through each object on this consumer (buttons, keys, etc.)
		int iccount = nextInputConsumer->getInputConsumerObjectCount();

		for(int j = 0; j < iccount; j++) {
			InputConsumerObject* nextObject = nextInputConsumer->getInputConsumerObject(j);

			if(nextObject) {
				nextObject->clearBindings();
			}
		}
	}
}

- (void)ReleaseEmulatorInputs {
	memset(_controller, 0, sizeof(_controller));
	_keyboard = 0;
	_keyboardDownCount = 0;
	_keyboardShiftCount = 0;

    if(!currentEmu) {
        ELOG(@"`currentEmu` is nil");
        return;
    }

	[self ReleasePeripheralInputs:currentEmu];
	UINT32 count = currentEmu->GetPeripheralCount();

	for(UINT32 i = 0; i < count; i++) {
		[self ReleasePeripheralInputs:currentEmu->GetPeripheral(i)];
	}
}

- (void)InitializePeripheralInputs:(Peripheral*)periph {
	/// iterate through all the emulated input consumers in the current emulator.
	/// these consumers represent the emulated joysticks, keyboards, etc. that were
	/// originally used to provide input to the emulated system
	UINT16 count = periph->GetInputConsumerCount();
	for(UINT16 i = 0; i < count; i++) {
		InputConsumer* nextInputConsumer = periph->GetInputConsumer(i);
		BOOL isKeyboard = dynamic_cast<ECSKeyboard*>(nextInputConsumer) ? TRUE : FALSE;

		//iterate through each object on this consumer (buttons, keys, etc.)
		int iccount = nextInputConsumer->getInputConsumerObjectCount();
		for(int j = 0; j < iccount; j++) {
			InputConsumerObject* nextObject = nextInputConsumer->getInputConsumerObject(j);

			if(nextObject) {
				INT32 _objectids[1] = {nextObject->getDefaultEnum()};
				INT32 *objectids = _objectids;
				InputProducer** producerList = new InputProducer*[0];
				BlissInputProducer *producer = new BlissInputProducer;

                producer->setPlayer(i);
				producer->setKeyboardDevice(isKeyboard);
				producerList[0] = producer;
				nextObject->addBinding(producerList, objectids, 1);
				delete[] producerList;
			}
		}
	}
}

- (void)InitializeEmulatorInputs {
	[self ReleaseEmulatorInputs];

	[self InitializePeripheralInputs:currentEmu];

	UINT32 count = currentEmu->GetPeripheralCount();

	for(UINT32 i = 0; i < count; i++) {
		[self InitializePeripheralInputs:currentEmu->GetPeripheral(i)];
	}
}

#pragma mark - OpenEmu Core

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    _ROMName = [path copy];

    NSError *loadRipError;
    BOOL loaded = [self LoadRip:path.fileSystemRepresentation error: &loadRipError];

	if(!loaded) {
        if (loadRipError) {
            *error = loadRipError;
        } else {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Failed to load ROM.",
                NSLocalizedFailureReasonErrorKey: FORMAT(@"Bliss failed to load `%@`", path),
                NSLocalizedRecoverySuggestionErrorKey: @"Try a different ROM file."
            };
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                        code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                    userInfo:userInfo];
        }
		return NO;
	}

	DLOG(@"Loaded File");

	// find the currentEmulator required to run this RIP
//    ID_SYSTEM_ATARI5200
//    ID_SYSTEM_INTELLIVISION
//	currentEmu = Emulator::GetEmulatorByID(currentRip->GetTargetSystemID());
    if ([self.systemIdentifier containsString:@"intellivision"]) {
        targetSystemID = ID_SYSTEM_INTELLIVISION;
    } else if ([self.systemIdentifier containsString:@"5200"]) {
        targetSystemID = ID_SYSTEM_ATARI5200;
    }
    currentEmu = Emulator::GetEmulatorByID(targetSystemID);

    if(currentEmu == nil) {
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Failed to load emulator core.",
            NSLocalizedFailureReasonErrorKey: @"Bliss failed to determine the correct sub-core.",
            NSLocalizedRecoverySuggestionErrorKey: @""
        };
        *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                userInfo:userInfo];
        return NO;
    }

	// load emulator ROMs
	if(![self loadROMForPeripheral:currentEmu]) {
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Failed to load peripheral BIOS.",
            NSLocalizedFailureReasonErrorKey: @"Bliss failed to load BIOS for peripheral.",
            NSLocalizedRecoverySuggestionErrorKey: @"Import the correct BIOSes."
        };
        *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                    code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                userInfo:userInfo];
		return NO;
	}

	// load peripheral ROMs
	INT32 count = currentEmu->GetPeripheralCount();
	for(INT32 i = 0; i < count; i++) {
		Peripheral* p = currentEmu->GetPeripheral(i);
		PeripheralCompatibility usage = currentRip->GetPeripheralUsage(p->GetShortName());
		if(usage == PERIPH_INCOMPATIBLE || usage == PERIPH_COMPATIBLE) {
			currentEmu->UsePeripheral(i, FALSE);
			continue;
		}

		BOOL loaded = [self loadROMForPeripheral:p];
		if(loaded) {
			//peripheral loaded, might as well use it.
			currentEmu->UsePeripheral(i, TRUE);
		} else if(usage == PERIPH_OPTIONAL) {
			//didn't load, but the peripheral is optional, so just skip it
			currentEmu->UsePeripheral(i, FALSE);
		} else {
			//usage == PERIPH_REQUIRED, but it didn't load
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Failed to load BIOS.",
                NSLocalizedFailureReasonErrorKey: @"Bliss failed to required load BIOS for peripheral.",
                NSLocalizedRecoverySuggestionErrorKey: @"Import the correct BIOS."
            };
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                        code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                    userInfo:userInfo];
			return NO;
		}
	}

	[self InitializeEmulatorInputs];

	// hook up the audio and video
	currentEmu->InitVideo(_videoBus, currentEmu->GetVideoWidth(), currentEmu->GetVideoHeight());
	currentEmu->InitAudio(_audioMixer, AUDIO_SAMPLE_RATE);

	// put the RIP in the currentEmulator
	currentEmu->SetRip(currentRip);

	// finally, run everything
	currentEmu->Reset();

    return YES;
}

- (void)resetEmulation {
	currentEmu->Reset();
}

- (void)stopEmulation {
	if(currentEmu) {
		currentEmu->SetRip(NULL);
		currentEmu->ReleaseAudio();
		currentEmu->ReleaseVideo();
		currentEmu = NULL;
	}

	if(currentRip) {
		delete currentRip;
		currentRip = NULL;
	}

    [super stopEmulation];
}

- (CGSize)bufferSize {
    return CGSizeMake(INTV_IMAGE_WIDTH, INTV_IMAGE_HEIGHT);
}

- (CGRect)screenRect {
    return CGRectMake(0, 0, INTV_IMAGE_WIDTH, INTV_IMAGE_HEIGHT);
}

- (CGSize)aspectSize {
    return CGSizeMake(INTV_IMAGE_WIDTH * (12.0/7.0), INTV_IMAGE_HEIGHT);
}

- (const void *)getVideoBufferWithHint:(void *)hint {
    if (!hint) {
        if (!_videoBuffer)
            _videoBuffer = new unsigned char[256 * 256 * 4];
        hint = _videoBuffer;
    }

    return _videoBuffer = (uint8_t*)hint;
}

- (const void *)videoBuffer {
    return [self getVideoBufferWithHint:nil];
}

//OpenGL doesn't support BGRA
- (GLenum)pixelFormat { return GL_RGBA; }

- (GLenum)internalPixelFormat { return GL_RGBA; }

- (GLenum)pixelType { return GL_UNSIGNED_BYTE; }

- (NSTimeInterval)frameInterval {
	// http://spatula-city.org/~im14u2c/intv/tech/master.html
	// Actual Effective Frame Rate
	return 59.92;
}

- (NSUInteger)channelCount { return 1; }

- (double)audioSampleRate { return AUDIO_SAMPLE_RATE; }

- (NSUInteger)audioBitDepth { return 16; }

- (id<RingBufferProtocol>)ringBufferAtIndex:(NSUInteger)index {
    return _audioBuffer;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError *))block {
	BOOL didSaveStateFile = NO;
	didSaveStateFile = currentEmu->SaveStateFile([fileName fileSystemRepresentation]);

    if (!didSaveStateFile) {
        NSDictionary *userInfo = @{
                                   NSLocalizedDescriptionKey: @"Failed to save state.",
                                   NSLocalizedFailureReasonErrorKey: @"Bliss failed to create save state.",
                                   NSLocalizedRecoverySuggestionErrorKey: @""
                                   };

        NSError *newError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                                code:PVEmulatorCoreErrorCodeCouldNotSaveState
                                            userInfo:userInfo];
        block(newError);
    } else {
        block(nil);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError *))block {
	BOOL didLoadStateFile = NO;

	// TODO: is this an emulator bug, a state bug, or a hardware necessity?
	// determine if this intellivision cart requires the ECS peripheral.
	// if it does, we need to 'warm up' the system with 5 frames before loading
	// the state in to the emulator. (only immediately following a reset - why?)
	if(currentRip->GetPeripheralUsage("ECS") == PERIPH_REQUIRED)
	{
		int warmUpECSFrameCount = 5;

		while(warmUpECSFrameCount > 0)
		{
			currentEmu->Run();
			warmUpECSFrameCount--;
		}
	}

	didLoadStateFile = currentEmu->LoadStateFile([fileName fileSystemRepresentation]);
    if (!didLoadStateFile) {
        NSDictionary *userInfo = @{
                                   NSLocalizedDescriptionKey: @"Failed to load state.",
                                   NSLocalizedFailureReasonErrorKey: @"Bliss failed to load save state.",
                                   NSLocalizedRecoverySuggestionErrorKey: @""
                                   };

        NSError *newError = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                                code:PVEmulatorCoreErrorCodeCouldNotSaveState
                                            userInfo:userInfo];
        block(newError);
    } else {
        block(nil);
    }
}

- (NSData *)serializeStateWithError:(NSError **)outError {
	void *stateBuffer = [_stateData mutableBytes];
	NSUInteger stateLength = [_stateData length];
	BOOL didSaveStateData = NO;

	didSaveStateData = currentEmu->SaveStateBuffer(stateBuffer, stateLength);

    if(didSaveStateData)
        return _stateData;

    if(outError) {
        *outError = [NSError errorWithDomain:@"com.provenance.core" code:2 userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
    }

    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError {
	const void *stateBuffer = [state bytes];
	NSUInteger stateLength = [_stateData length];
	BOOL didLoadStateData = NO;

	didLoadStateData = currentEmu->LoadStateBuffer(stateBuffer, stateLength);

    if(didLoadStateData)
        return YES;

    if(outError) {
        *outError = [NSError errorWithDomain:@"com.provenance.core" code:1 userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read"
        }];
    }

    return NO;
}


#pragma mark -

/*
 Bliss callbacks
 */

#pragma mark Bliss Audio Mixer

void BlissAudioMixer::init(UINT32 sampleRate) {
    @autoreleasepool {
    GET_CURRENT_OR_RETURN();

	int sampleInterval = (sampleRate / [current frameInterval]);

	// initialize the sampleBuffer
	AudioMixer::init(sampleRate);

    int bufferLength = (sizeof(INT16) * sampleInterval * 8) * 2;
    current->_audioBuffer = [RingBufferFactory makeWithType:RingBufferTypeProvenance
                                                      withLength:bufferLength];
		}
}

void BlissAudioMixer::release() {
	AudioMixer::release();
}

void BlissAudioMixer::flushAudio() {
    GET_CURRENT_OR_RETURN();

	NSUInteger bytesPerSample = sizeof(INT16);
	NSUInteger bytesToWrite = sampleCount * bytesPerSample;

    dispatch_async(current->audioQueue, ^{
        [current->_bufferLock lock];
        [current->_audioBuffer write:this->sampleBuffer size:bytesToWrite];
        [current->_bufferLock unlock];

        // updates buffer write position and sample count
        AudioMixer::flushAudio();
    });
}

#pragma mark Bliss Video Bus

void BlissVideoBus::init(UINT32 width, UINT32 height) {
	VideoBus::init(width, height);
}

void BlissVideoBus::release() {
    GET_CURRENT_OR_RETURN();

    if (current->_videoBuffer) {
        delete[] current->_videoBuffer;
        current->_videoBuffer = NULL;
    }

	VideoBus::release();
}

void BlissVideoBus::render() {
    GET_CURRENT_OR_RETURN();

	VideoBus::render();

	[current->_bufferLock lock];
	memcpy([current videoBuffer], this->pixelBuffer, this->pixelBufferSize);
	[current->_bufferLock unlock];
}

#pragma mark Bliss Input Producer

BlissInputProducer::BlissInputProducer()
: InputProducer((GUID){0}) {
}

float BlissInputProducer::getValue(INT32 enumeration) {
	BOOL isKeyboardDevice = this->isKeyboardDevice();
	int player = this->player;
	float value = 0.0f;

	if(isKeyboardDevice) {
		uint64_t keyflag = INTY_TO_BITMAP(enumeration);

		value = INTY_TEST(_keyboard, keyflag) == keyflag ? 1.0f : 0.0f;
	} else {
		if(enumeration >= CONTROLLER_DISC_DOWN && enumeration <= CONTROLLER_DISC_UP_LEFT) {
			value = INTY_TEST(_controller[player].disc, enumeration) == enumeration ? 1.0f : 0.0f;
		} else if(enumeration == CONTROLLER_ACTION_TOP || enumeration == CONTROLLER_ACTION_BOTTOM_LEFT || enumeration == CONTROLLER_ACTION_BOTTOM_RIGHT) {
			value = INTY_TEST(_controller[player].action, enumeration) == enumeration ? 1.0f : 0.0f;
		} else if(enumeration >= CONTROLLER_KEYPAD_THREE && enumeration <= CONTROLLER_KEYPAD_CLEAR) {
			value = INTY_TEST(_controller[player].keypad, enumeration) == enumeration ? 1.0f : 0.0f;
		}
        
        //This is useful when debugging to see that input is correctly being passed back to the core
        printf("*** enumeration %d, value %f, player %d\n", enumeration, value, player);
	}
	return value;
}

#pragma mark - PVIntellivisionSystemResponderClient

- (void)updateControllers
{
    if ([self.controller1 extendedGamepad])
    {
        //TODO: fully implement support for controllers (might be tough, Intellivision controller doesn't map to moderns)
        GCExtendedGamepad *gamepad = [self.controller1 extendedGamepad];
        GCControllerDirectionPad *dpad = [gamepad dpad];
        
//        [self setIntellivisionButton:CONTROLLER_DISC_UP isDown:(dpad.up.isPressed || gamepad.leftThumbstick.up.isPressed) forPlayer:1];
//        [self setIntellivisionButton:CONTROLLER_DISC_DOWN isDown:(dpad.down.isPressed || gamepad.leftThumbstick.down.isPressed) forPlayer:1];
//        [self setIntellivisionButton:CONTROLLER_DISC_LEFT isDown:(dpad.left.isPressed || gamepad.leftThumbstick.left.isPressed) forPlayer:1];
//        [self setIntellivisionButton:CONTROLLER_DISC_RIGHT isDown:(dpad.right.isPressed || gamepad.leftThumbstick.right.isPressed) forPlayer:1];
//        
//        [self setIntellivisionButton:CONTROLLER_ACTION_TOP isDown:(gamepad.buttonA.isPressed) forPlayer:1];
//        [self setIntellivisionButton:CONTROLLER_ACTION_BOTTOM_LEFT isDown:(gamepad.buttonB.isPressed) forPlayer:1];
//        [self setIntellivisionButton:CONTROLLER_ACTION_BOTTOM_RIGHT isDown:(gamepad.buttonX.isPressed) forPlayer:1];
    }
}

- (int)blissButtonForIntellivisionButton:(PVIntellivisionButton)button player:(NSUInteger)player; {
    int btn = -1;
	static int OEBlissIntellivisionButton[] =
	{
		CONTROLLER_DISC_UP,
		CONTROLLER_DISC_DOWN,
		CONTROLLER_DISC_LEFT,
		CONTROLLER_DISC_RIGHT,
		CONTROLLER_ACTION_TOP,
		CONTROLLER_ACTION_BOTTOM_LEFT,
		CONTROLLER_ACTION_BOTTOM_RIGHT,
		CONTROLLER_KEYPAD_ONE,
		CONTROLLER_KEYPAD_TWO,
		CONTROLLER_KEYPAD_THREE,
		CONTROLLER_KEYPAD_FOUR,
		CONTROLLER_KEYPAD_FIVE,
		CONTROLLER_KEYPAD_SIX,
		CONTROLLER_KEYPAD_SEVEN,
		CONTROLLER_KEYPAD_EIGHT,
		CONTROLLER_KEYPAD_NINE,
		CONTROLLER_KEYPAD_ZERO,
		CONTROLLER_KEYPAD_CLEAR,
		CONTROLLER_KEYPAD_ENTER
	};

	if(button < PVIntellivisionButtonCount && button >= PVIntellivisionButtonUp) {
		btn = OEBlissIntellivisionButton[button];
	}

	return btn;
}

- (oneway void)setIntellivisionButton:(int)btn isDown:(BOOL)down forPlayer:(NSUInteger)player {
    //this is new, so we should re-look at this, but there was a bug here.
    if (player == 0) { player = 1; }
	switch(btn)
	{
		case CONTROLLER_DISC_DOWN:
		case CONTROLLER_DISC_RIGHT:
		case CONTROLLER_DISC_UP:
		case CONTROLLER_DISC_LEFT: {
			_controller[player-1].disc = down ?
				INTY_ON(_controller[player-1].disc, btn) :
				INTY_OFF(_controller[player-1].disc, btn);
			// if both horizontal + vertical disc directions are active,
			// turn on the wide bit flag for 45-degree angles
			if((_controller[player-1].disc & (CONTROLLER_DISC_LEFT|CONTROLLER_DISC_RIGHT))
			   && (_controller[player-1].disc & (CONTROLLER_DISC_UP|CONTROLLER_DISC_DOWN))) {
				INTY_ON(_controller[player-1].disc, CONTROLLER_DISC_WIDE);
			} else {
				INTY_OFF(_controller[player-1].disc, CONTROLLER_DISC_WIDE);
			}
			break;
		}
		case CONTROLLER_KEYPAD_ONE:
		case CONTROLLER_KEYPAD_TWO:
		case CONTROLLER_KEYPAD_THREE:
		case CONTROLLER_KEYPAD_FOUR:
		case CONTROLLER_KEYPAD_FIVE:
		case CONTROLLER_KEYPAD_SIX:
		case CONTROLLER_KEYPAD_SEVEN:
		case CONTROLLER_KEYPAD_EIGHT:
		case CONTROLLER_KEYPAD_NINE:
		case CONTROLLER_KEYPAD_CLEAR:
		case CONTROLLER_KEYPAD_ZERO:
		case CONTROLLER_KEYPAD_ENTER:
			_controller[player-1].keypad = down ?
				INTY_ON(_controller[player-1].keypad, btn) :
				INTY_OFF(_controller[player-1].keypad, btn);
			break;
		case CONTROLLER_ACTION_TOP:
		case CONTROLLER_ACTION_BOTTOM_LEFT:
		case CONTROLLER_ACTION_BOTTOM_RIGHT:
			_controller[player-1].action = down ?
				INTY_ON(_controller[player-1].action, btn) :
				INTY_OFF(_controller[player-1].action, btn);
			break;
		default: break;
	}
}

- (void)didPushIntellivisionButton:(PVIntellivisionButton)button forPlayer:(NSInteger)player; {
    int btn = [self blissButtonForIntellivisionButton:button player:player];

	if(btn > -1) {
		[self setIntellivisionButton:btn isDown:YES forPlayer:player];
	}
}

- (void)didReleaseIntellivisionButton:(PVIntellivisionButton)button forPlayer:(NSInteger)player; {
    int btn = [self blissButtonForIntellivisionButton:button player:player];

	if(btn > -1) {
		[self setIntellivisionButton:btn isDown:NO forPlayer:player];
	}
}

- (int)intellivisionKeyForKeyCode:(unsigned short)keyCode {
	int btn = -1;
#if !TARGET_OS_OSX
    switch(keyCode) {
		default: break;
		case UIKeyboardHIDUsageKeyboardA: btn = ECS_KEYBOARD_A; break;
		case UIKeyboardHIDUsageKeyboardB: btn = ECS_KEYBOARD_B; break;
		case UIKeyboardHIDUsageKeyboardC: btn = ECS_KEYBOARD_C; break;
		case UIKeyboardHIDUsageKeyboardD: btn = ECS_KEYBOARD_D; break;
		case UIKeyboardHIDUsageKeyboardE: btn = ECS_KEYBOARD_E; break;
		case UIKeyboardHIDUsageKeyboardF: btn = ECS_KEYBOARD_F; break;
		case UIKeyboardHIDUsageKeyboardG: btn = ECS_KEYBOARD_G; break;
		case UIKeyboardHIDUsageKeyboardH: btn = ECS_KEYBOARD_H; break;
		case UIKeyboardHIDUsageKeyboardI: btn = ECS_KEYBOARD_I; break;
		case UIKeyboardHIDUsageKeyboardJ: btn = ECS_KEYBOARD_J; break;
		case UIKeyboardHIDUsageKeyboardK: btn = ECS_KEYBOARD_K; break;
		case UIKeyboardHIDUsageKeyboardL: btn = ECS_KEYBOARD_L; break;
		case UIKeyboardHIDUsageKeyboardM: btn = ECS_KEYBOARD_M; break;
		case UIKeyboardHIDUsageKeyboardN: btn = ECS_KEYBOARD_N; break;
		case UIKeyboardHIDUsageKeyboardO: btn = ECS_KEYBOARD_O; break;
		case UIKeyboardHIDUsageKeyboardP: btn = ECS_KEYBOARD_P; break;
		case UIKeyboardHIDUsageKeyboardQ: btn = ECS_KEYBOARD_Q; break;
		case UIKeyboardHIDUsageKeyboardR: btn = ECS_KEYBOARD_R; break;
		case UIKeyboardHIDUsageKeyboardS: btn = ECS_KEYBOARD_S; break;
		case UIKeyboardHIDUsageKeyboardT: btn = ECS_KEYBOARD_T; break;
		case UIKeyboardHIDUsageKeyboardU: btn = ECS_KEYBOARD_U; break;
		case UIKeyboardHIDUsageKeyboardV: btn = ECS_KEYBOARD_V; break;
		case UIKeyboardHIDUsageKeyboardW: btn = ECS_KEYBOARD_W; break;
		case UIKeyboardHIDUsageKeyboardX: btn = ECS_KEYBOARD_X; break;
		case UIKeyboardHIDUsageKeyboardY: btn = ECS_KEYBOARD_Y; break;
		case UIKeyboardHIDUsageKeyboardZ: btn = ECS_KEYBOARD_Z; break;

		case UIKeyboardHIDUsageKeyboard1: btn = ECS_KEYBOARD_1; break;
		case UIKeyboardHIDUsageKeyboard2: btn = ECS_KEYBOARD_2; break;
		case UIKeyboardHIDUsageKeyboard3: btn = ECS_KEYBOARD_3; break;
		case UIKeyboardHIDUsageKeyboard4: btn = ECS_KEYBOARD_4; break;
		case UIKeyboardHIDUsageKeyboard5: btn = ECS_KEYBOARD_5; break;
		case UIKeyboardHIDUsageKeyboard6: btn = ECS_KEYBOARD_6; break;
		case UIKeyboardHIDUsageKeyboard7: btn = ECS_KEYBOARD_7; break;
		case UIKeyboardHIDUsageKeyboard8: btn = ECS_KEYBOARD_8; break;
		case UIKeyboardHIDUsageKeyboard9: btn = ECS_KEYBOARD_9; break;
		case UIKeyboardHIDUsageKeyboard0: btn = ECS_KEYBOARD_0; break;

		case UIKeyboardHIDUsageKeyboardReturnOrEnter: btn = ECS_KEYBOARD_RETURN; break;
		case UIKeyboardHIDUsageKeyboardEscape: btn = ECS_KEYBOARD_ESCAPE; break;
		case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: btn = ECS_KEYBOARD_LEFT; break;
		case UIKeyboardHIDUsageKeyboardSpacebar: btn = ECS_KEYBOARD_SPACE; break;

		case UIKeyboardHIDUsageKeyboardHyphen: btn = ECS_KEYBOARD_6; break; // shifted
		case UIKeyboardHIDUsageKeyboardEqualSign: btn = ECS_KEYBOARD_1; break; // shifted
		case UIKeyboardHIDUsageKeyboardSemicolon: btn = ECS_KEYBOARD_SEMICOLON; break;
		case UIKeyboardHIDUsageKeyboardQuote: btn = ECS_KEYBOARD_RIGHT; break; // shifted
		case UIKeyboardHIDUsageKeyboardComma: btn = ECS_KEYBOARD_COMMA; break;
		case UIKeyboardHIDUsageKeyboardPeriod: btn = ECS_KEYBOARD_PERIOD; break;
		case UIKeyboardHIDUsageKeyboardSlash: btn = ECS_KEYBOARD_7; break; // shifted

		case UIKeyboardHIDUsageKeyboardRightArrow: btn = ECS_KEYBOARD_RIGHT; break;
		case UIKeyboardHIDUsageKeyboardLeftArrow: btn = ECS_KEYBOARD_LEFT; break;
		case UIKeyboardHIDUsageKeyboardDownArrow: btn = ECS_KEYBOARD_DOWN; break;
		case UIKeyboardHIDUsageKeyboardUpArrow: btn = ECS_KEYBOARD_UP; break;

		case UIKeyboardHIDUsageKeyboardReturn: btn = ECS_KEYBOARD_RETURN; break;

		case UIKeyboardHIDUsageKeyboardLeftControl:
		case UIKeyboardHIDUsageKeyboardRightControl: btn = ECS_KEYBOARD_CONTROL; break;
		case UIKeyboardHIDUsageKeyboardLeftShift:
		case UIKeyboardHIDUsageKeyboardRightShift: btn = ECS_KEYBOARD_SHIFT; break;
	}
#endif

	return btn;
}

- (BOOL)isIntellivisionKeyShiftedForKeycode:(unsigned short)keyCode {
#if !TARGET_OS_OSX
	switch(keyCode)
	{
		default: break;
		case UIKeyboardHIDUsageKeyboardLeftShift:
		case UIKeyboardHIDUsageKeyboardRightShift: return YES; break;

		case UIKeyboardHIDUsageKeyboardHyphen: return YES; break;
		case UIKeyboardHIDUsageKeyboardEqualSign: return YES; break;
		case UIKeyboardHIDUsageKeyboardQuote: return YES; break;
		case UIKeyboardHIDUsageKeyboardSlash: return YES; break;
	}
#endif
	return NO;
}

- (void)setIntellivisionKey:(int)key isDown:(BOOL)down isShifted:(BOOL)shifted {
	uint64_t shiftflag = INTY_TO_BITMAP(ECS_KEYBOARD_SHIFT);

	// HACK: double re-map
	if(_keyboardShiftCount > 0) {
		switch(key) {
			default: break;
			case ECS_KEYBOARD_1: key = ECS_KEYBOARD_5; break;
			case ECS_KEYBOARD_5: key = ECS_KEYBOARD_LEFT; break;
			case ECS_KEYBOARD_6: key = ECS_KEYBOARD_UP; break;
			case ECS_KEYBOARD_7: key = ECS_KEYBOARD_DOWN; break;
			case ECS_KEYBOARD_RIGHT: key = ECS_KEYBOARD_2; break;
		}
	}

	if(shifted) {
		if(down) {
			if(_keyboardShiftCount == 0) {
				INTY_ON(_keyboard, shiftflag);
			}
			_keyboardShiftCount++;
		} else {
			_keyboardShiftCount--;

			if(_keyboardShiftCount == 0)
			{
				INTY_OFF(_keyboard, shiftflag);
			}
		}
		//DLOG(@"_keyboardShiftCount == %i", _keyboardShiftCount);
	}

	uint64_t keyflag = INTY_TO_BITMAP(key);

	if(down) {
		INTY_ON(_keyboard, keyflag);
		_keyboardDownCount++;
	} else {
		INTY_OFF(_keyboard, keyflag);
		_keyboardDownCount--;

		if(_keyboardDownCount == 0)
		{
			_keyboard = 0;
		}
	}
	//DLOG(@"_keyboardDownCount == %i", _keyboardDownCount);
}

- (oneway void)keyDown:(unsigned short)keyCode {
	int key = [self intellivisionKeyForKeyCode:keyCode];

	if(key > -1) {
		BOOL shifted = [self isIntellivisionKeyShiftedForKeycode:keyCode];

		[self setIntellivisionKey:key isDown:YES isShifted:shifted];
	}
}

- (oneway void)keyUp:(unsigned short)keyCode {
	int key = [self intellivisionKeyForKeyCode:keyCode];

	if(key > -1) {
		BOOL shifted = [self isIntellivisionKeyShiftedForKeycode:keyCode];

		[self setIntellivisionKey:key isDown:NO isShifted:shifted];
	}
}

@end
