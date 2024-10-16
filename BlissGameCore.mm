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

#import "BlissGameCore.h"

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

#import <PVSupport/PVSupport-Swift.h>

#import "core/Emulator.h"
#import "core/rip/Rip.h"
#import "core/audio/AudioMixer.h"
#import "core/video/VideoBus.h"
#import "drivers/intv/Intellivision.h"
#import "drivers/intv/HandController.h"
#import "drivers/intv/ECSKeyboard.h"

#define INTV_IMAGE_WIDTH	(160)
#define INTV_IMAGE_HEIGHT	(192)

#define KEYBOARD_OBJECT_COUNT 256
#define AUDIO_SAMPLE_RATE 48000

#define INTY_TO_BITMAP(bits)  (1ULL << (uint64_t)(bits))

#define INTY_TEST(bits, flag) ((bits) &   (uint64_t)(flag))
#define INTY_ON(bits, flag)   ((bits) |=  (uint64_t)(flag))
#define INTY_OFF(bits, flag)  ((bits) &= ~(uint64_t)(flag))

typedef struct
{
	UINT16	keypad;
	UINT16	action;
	UINT16	disc;
} BlissController;

class BlissInputProducer : public InputProducer
{
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

	void setPlayer(CHAR playerIndex) {
		player = playerIndex;
	}

private:
	CHAR player;
	BOOL keyboardDevice;
};

class BlissAudioMixer : public AudioMixer
{
public:
	void		init(UINT32 sampleRate);
	void		release();
	void		flushAudio();
};

class BlissVideoBus : public VideoBus
{
public:
	void		init(UINT32 width, UINT32 height);
	void		release();
	void		render();
};

@interface PVBlissGameCore () <PVIntellivisionSystemResponderClient>
{
	NSLock			*_bufferLock;
	OERingBuffer	*_audioBuffer;
	unsigned char	*_videoBuffer;
	BlissAudioMixer	*_audioMixer;
	BlissVideoBus	*_videoBus;

    NSString		*_ROMName;
	Emulator		*currentEmu;
	Rip				*currentRip;

	NSMutableData	*_stateData;
}
- (int)blissButtonForIntellivisionButton:(PVIntellivisionButton)button player:(NSUInteger)player;
@end

@implementation PVBlissGameCore

// Global variables because the callbacks need to access them...
static PVBlissGameCore *_currentCore;
static BlissController _controller[2] = {0};
static uint64_t _keyboard = 0;
static uint8_t _keyboardDownCount = 0;
static uint8_t _keyboardShiftCount = 0;

#pragma mark - OpenEmu Core

/*
 OpenEmu Core internal functions
 */

- (id)init
{
    self = [super init];
    if(self != nil)
    {
        _bufferLock = [[NSLock alloc] init];

		_currentCore = self;

		_audioMixer = new BlissAudioMixer;
		_videoBus = new BlissVideoBus;

		_stateData = [NSMutableData dataWithLength:sizeof(IntellivisionState)];
    }

    return self;
}

- (void)dealloc
{
    DLog(@"releasing/deallocating Bliss memory");

	delete _videoBus;
	_videoBus = NULL;
	delete _audioMixer;
	_audioMixer = NULL;

	_currentCore = NULL;
}

- (void)executeFrame
{
    //DLog(@"Executing");

	// run the emulation
	currentEmu->Run();

	// render and display the video
	currentEmu->Render();

	// flush the audio
	currentEmu->FlushAudio();
}

#pragma mark - Bliss Core Helpers

- (BOOL)LoadRip:(const char*)filename
{
	char cfgFilename[PATH_MAX] = {0};
	NSString *cfgString = [[NSBundle bundleForClass:[self class]] pathForResource:@"knowncarts" ofType:@"cfg" inDirectory:@""];
	strncpy(cfgFilename, cfgString.fileSystemRepresentation, sizeof(cfgFilename));

	if(!cfgFilename[0])
		return FALSE;

	if(strlen(filename) < 5)
		return FALSE;

	const CHAR* extStart = filename + strlen(filename) - 4;
	if(strcmpi(extStart, ".intv") == 0 || strcmpi(extStart, ".int") == 0 || strcmpi(extStart, ".bin") == 0)
	{
		//load the bin file as a Rip
		currentRip = Rip::LoadBin(filename, cfgFilename);
		if(currentRip == NULL)
			return FALSE;
	}
	else if(strcmpi(extStart, ".a52") == 0)
	{
		//load the bin file as a Rip
		currentRip = Rip::LoadA52(filename);
		if(currentRip == NULL)
			return FALSE;

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else if(strcmpi(extStart, ".irom") == 0 || strcmpi(extStart, ".rom") == 0)
	{
		//load the rom file as a Rip
		currentRip = Rip::LoadRom(filename);
		if(currentRip == NULL)
			return FALSE;

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else if(strcmpi(extStart, ".zip") == 0)
	{
		//load the zip file as a Rip
		currentRip = Rip::LoadZip(filename, cfgFilename);
		if(currentRip == NULL)
			return FALSE;

		CHAR fileSubname[MAX_PATH];
		const CHAR* filenameStart = strrchr(filename, '/')+1;
		strncpy(fileSubname, filenameStart, strlen(filenameStart)-4);
		*(fileSubname+strlen(filenameStart)-4) = NULL;
	}
	else
	{
		//load the designated Rip
		currentRip = Rip::LoadRip(filename);
		if(currentRip == NULL)
			return FALSE;
	}

	return TRUE;
}

- (BOOL)loadROMForPeripheral:(Peripheral*)peripheral
{
	BOOL didLoadROMs = NO;
	NSString *BIOSPath = nil;
	UINT16 count = peripheral->GetROMCount();

	for(UINT16 i = 0; i < count; i++)
	{
		ROM* r = peripheral->GetROM(i);
		if(r->isLoaded())
		{
			didLoadROMs = YES;
			continue;
		}

		BIOSPath = [[self BIOSPath] stringByAppendingString:[NSString stringWithFormat:@"/%s", r->getDefaultFileName()]];

		if(r->load([BIOSPath fileSystemRepresentation], r->getDefaultFileOffset()))
		{
			didLoadROMs = YES;
		}
		else
		{
			didLoadROMs = NO;
			break;
		}
	}

	return didLoadROMs;
}

- (void)ReleasePeripheralInputs:(Peripheral*)periph
{
	UINT16 count = periph->GetInputConsumerCount();

	for(UINT16 i = 0; i < count; i++)
	{
		InputConsumer* nextInputConsumer = periph->GetInputConsumer(i);

		//iterate through each object on this consumer (buttons, keys, etc.)
		int iccount = nextInputConsumer->getInputConsumerObjectCount();

		for(int j = 0; j < iccount; j++)
		{
			InputConsumerObject* nextObject = nextInputConsumer->getInputConsumerObject(j);

			if(nextObject)
			{
				nextObject->clearBindings();
			}
		}
	}
}

- (void)ReleaseEmulatorInputs
{
	memset(_controller, 0, sizeof(_controller));
	_keyboard = 0;
	_keyboardDownCount = 0;
	_keyboardShiftCount = 0;

	if(!currentEmu)
		return;

	[self ReleasePeripheralInputs:currentEmu];
	UINT32 count = currentEmu->GetPeripheralCount();

	for(UINT32 i = 0; i < count; i++)
	{
		[self ReleasePeripheralInputs:currentEmu->GetPeripheral(i)];
	}
}

- (void)InitializePeripheralInputs:(Peripheral*)periph
{
	//iterate through all the emulated input consumers in the current emulator.
	//these consumers represent the emulated joysticks, keyboards, etc. that were
	//originally used to provide input to the emulated system
	UINT16 count = periph->GetInputConsumerCount();
	for(UINT16 i = 0; i < count; i++)
	{
		InputConsumer* nextInputConsumer = periph->GetInputConsumer(i);
		BOOL isKeyboard = dynamic_cast<ECSKeyboard*>(nextInputConsumer) ? TRUE : FALSE;

		//iterate through each object on this consumer (buttons, keys, etc.)
		int iccount = nextInputConsumer->getInputConsumerObjectCount();
		for(int j = 0; j < iccount; j++)
		{
			InputConsumerObject* nextObject = nextInputConsumer->getInputConsumerObject(j);

			if(nextObject)
			{
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

- (void)InitializeEmulatorInputs
{
	[self ReleaseEmulatorInputs];

	[self InitializePeripheralInputs:currentEmu];

	UINT32 count = currentEmu->GetPeripheralCount();

	for(UINT32 i = 0; i < count; i++)
	{
		[self InitializePeripheralInputs:currentEmu->GetPeripheral(i)];
	}
}

#pragma mark - OpenEmu Core

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _ROMName = [path copy];

	if(![self LoadRip:path.fileSystemRepresentation])
	{
		return FALSE;
	}

	DLog(@"Loaded File");

	// find the currentEmulator required to run this RIP
	currentEmu = Emulator::GetEmulatorByID(currentRip->GetTargetSystemID());

	// load emulator ROMs
	if(![self loadROMForPeripheral:currentEmu])
	{
		return NO;
	}

	// load peripheral ROMs
	INT32 count = currentEmu->GetPeripheralCount();
	for(INT32 i = 0; i < count; i++)
	{
		Peripheral* p = currentEmu->GetPeripheral(i);
		PeripheralCompatibility usage = currentRip->GetPeripheralUsage(p->GetShortName());
		if(usage == PERIPH_INCOMPATIBLE || usage == PERIPH_COMPATIBLE)
		{
			currentEmu->UsePeripheral(i, FALSE);
			continue;
		}

		BOOL loaded = [self loadROMForPeripheral:p];
		if(loaded)
		{
			//peripheral loaded, might as well use it.
			currentEmu->UsePeripheral(i, TRUE);
		}
		else if(usage == PERIPH_OPTIONAL)
		{
			//didn't load, but the peripheral is optional, so just skip it
			currentEmu->UsePeripheral(i, FALSE);
		}
		else
		{
			//usage == PERIPH_REQUIRED, but it didn't load
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

- (void)resetEmulation
{
	currentEmu->Reset();
}

- (void)stopEmulation
{
	if(currentEmu)
	{
		currentEmu->SetRip(NULL);
		currentEmu->ReleaseAudio();
		currentEmu->ReleaseVideo();
		currentEmu = NULL;
	}

	if(currentRip)
	{
		delete currentRip;
		currentRip = NULL;
	}

    [super stopEmulation];
}

- (CGSize)bufferSize
{
    return CGSizeMake(INTV_IMAGE_WIDTH, INTV_IMAGE_HEIGHT);
}

- (CGRect)screenRect
{
    return CGRectMake(0, 0, INTV_IMAGE_WIDTH, INTV_IMAGE_HEIGHT);
}

- (CGSize)aspectSize
{
    return CGSizeMake(INTV_IMAGE_WIDTH * (12.0/7.0), INTV_IMAGE_HEIGHT);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint) {
        if (!_videoBuffer) _videoBuffer = new unsigned char[256 * 256 * 4];
        hint = _videoBuffer;
    }

    return _videoBuffer = (uint8_t*)hint;
}

- (const void *)videoBuffer {
    return [self getVideoBufferWithHint:nil];
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)internalPixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT;
//    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSTimeInterval)frameInterval
{
	// http://spatula-city.org/~im14u2c/intv/tech/master.html
	// Actual Effective Frame Rate
	return 59.92;
}

- (NSUInteger)channelCount
{
	return 1;
}

- (double)audioSampleRate
{
    return AUDIO_SAMPLE_RATE;
}

- (NSUInteger)audioBitDepth
{
	return 16;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	BOOL didSaveStateFile = NO;
	didSaveStateFile = currentEmu->SaveStateFile([fileName fileSystemRepresentation]);
    block(didSaveStateFile, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
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
    block(didLoadStateFile, nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
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

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
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

void BlissAudioMixer::init(UINT32 sampleRate)
{
	int sampleInterval = (sampleRate / [_currentCore frameInterval]);

	// initialize the sampleBuffer
	AudioMixer::init(sampleRate);

	_currentCore->_audioBuffer = [_currentCore ringBufferAtIndex:0];

	if(_currentCore->_audioBuffer)
	{
#warning May not need this
		[_currentCore->_audioBuffer setLength:(sizeof(INT16) * sampleInterval * 8)];
	}
}

void BlissAudioMixer::release()
{
	AudioMixer::release();
}

void BlissAudioMixer::flushAudio()
{
	NSUInteger bytesPerSample = sizeof(INT16);
	NSUInteger bytesToWrite = sampleCount * bytesPerSample;

	[_currentCore->_bufferLock lock];
	[_currentCore->_audioBuffer write:this->sampleBuffer maxLength:bytesToWrite];
	[_currentCore->_bufferLock unlock];

	// updates buffer write position and sample count
	AudioMixer::flushAudio();
}

#pragma mark Bliss Video Bus

void BlissVideoBus::init(UINT32 width, UINT32 height)
{
	VideoBus::init(width, height);
}

void BlissVideoBus::release()
{
    if (_currentCore->_videoBuffer) {
        delete[] _currentCore->_videoBuffer;
        _currentCore->_videoBuffer = NULL;
    }

	VideoBus::release();
}

void BlissVideoBus::render()
{
	VideoBus::render();

	[_currentCore->_bufferLock lock];
	memcpy(_currentCore->_videoBuffer, this->pixelBuffer, this->pixelBufferSize);
	[_currentCore->_bufferLock unlock];
}

#pragma mark Bliss Input Producer

BlissInputProducer::BlissInputProducer()
: InputProducer((GUID){0})
{
}

float BlissInputProducer::getValue(INT32 enumeration)
{
	BOOL isKeyboardDevice = this->isKeyboardDevice();
	char player = this->player;
	float value = 0.0f;

	if(isKeyboardDevice)
	{
		uint64_t keyflag = INTY_TO_BITMAP(enumeration);

		value = INTY_TEST(_keyboard, keyflag) == keyflag ? 1.0f : 0.0f;
	}
	else
	{
		if(enumeration >= CONTROLLER_DISC_DOWN && enumeration <= CONTROLLER_DISC_UP_LEFT)
		{
			value = INTY_TEST(_controller[player].disc, enumeration) == enumeration ? 1.0f : 0.0f;
		}
		else if(enumeration == CONTROLLER_ACTION_TOP || enumeration == CONTROLLER_ACTION_BOTTOM_LEFT || enumeration == CONTROLLER_ACTION_BOTTOM_RIGHT)
		{
			value = INTY_TEST(_controller[player].action, enumeration) == enumeration ? 1.0f : 0.0f;
		}
		else if(enumeration >= CONTROLLER_KEYPAD_THREE && enumeration <= CONTROLLER_KEYPAD_CLEAR)
		{
			value = INTY_TEST(_controller[player].keypad, enumeration) == enumeration ? 1.0f : 0.0f;
		}
	}

	return value;
}

#pragma mark - PVIntellivisionSystemResponderClient

- (int)blissButtonForIntellivisionButton:(PVIntellivisionButton)button player:(NSUInteger)player;
{
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

	if(button < PVIntellivisionButtonCount && button >= PVIntellivisionButtonUp)
	{
		btn = OEBlissIntellivisionButton[button];
	}

	return btn;
}

- (oneway void)setIntellivisionButton:(int)btn isDown:(BOOL)down forPlayer:(NSUInteger)player
{
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
			   && (_controller[player-1].disc & (CONTROLLER_DISC_UP|CONTROLLER_DISC_DOWN)))
			{
				INTY_ON(_controller[player-1].disc, CONTROLLER_DISC_WIDE);
			}
			else
			{
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

- (void)didPushIntellivisionButton:(PVIntellivisionButton)button forPlayer:(NSInteger)player;
{
    int btn = [self blissButtonForIntellivisionButton:button player:player];
    
	if(btn > -1)
	{
		[self setIntellivisionButton:btn isDown:YES forPlayer:player];
	}
}

- (void)didReleaseIntellivisionButton:(PVIntellivisionButton)button forPlayer:(NSInteger)player;
{
    int btn = [self blissButtonForIntellivisionButton:button player:player];
    
	if(btn > -1)
	{
		[self setIntellivisionButton:btn isDown:NO forPlayer:player];
	}
}

- (int)intellivisionKeyForKeyCode:(unsigned short)keyCode
{
	int btn = -1;
#if !TARGET_OS_OSX
    switch(keyCode)
	{
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

- (BOOL)isIntellivisionKeyShiftedForKeycode:(unsigned short)keyCode
{
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

- (void)setIntellivisionKey:(int)key isDown:(BOOL)down isShifted:(BOOL)shifted
{
	uint64_t shiftflag = INTY_TO_BITMAP(ECS_KEYBOARD_SHIFT);

	// HACK: double re-map
	if(_keyboardShiftCount > 0)
	{
		switch(key)
		{
			default: break;
			case ECS_KEYBOARD_1: key = ECS_KEYBOARD_5; break;
			case ECS_KEYBOARD_5: key = ECS_KEYBOARD_LEFT; break;
			case ECS_KEYBOARD_6: key = ECS_KEYBOARD_UP; break;
			case ECS_KEYBOARD_7: key = ECS_KEYBOARD_DOWN; break;
			case ECS_KEYBOARD_RIGHT: key = ECS_KEYBOARD_2; break;
		}
	}

	if(shifted)
	{
		if(down)
		{
			if(_keyboardShiftCount == 0)
			{
				INTY_ON(_keyboard, shiftflag);
			}
			_keyboardShiftCount++;
		}
		else
		{
			_keyboardShiftCount--;

			if(_keyboardShiftCount == 0)
			{
				INTY_OFF(_keyboard, shiftflag);
			}
		}
		//DLog(@"_keyboardShiftCount == %i", _keyboardShiftCount);
	}

	uint64_t keyflag = INTY_TO_BITMAP(key);

	if(down)
	{
		INTY_ON(_keyboard, keyflag);
		_keyboardDownCount++;
	}
	else
	{
		INTY_OFF(_keyboard, keyflag);
		_keyboardDownCount--;

		if(_keyboardDownCount == 0)
		{
			_keyboard = 0;
		}
	}
	//DLog(@"_keyboardDownCount == %i", _keyboardDownCount);
}

- (oneway void)keyDown:(unsigned short)keyCode
{
	int key = [self intellivisionKeyForKeyCode:keyCode];

	if(key > -1)
	{
		BOOL shifted = [self isIntellivisionKeyShiftedForKeycode:keyCode];

		[self setIntellivisionKey:key isDown:YES isShifted:shifted];
	}
}

- (oneway void)keyUp:(unsigned short)keyCode
{
	int key = [self intellivisionKeyForKeyCode:keyCode];

	if(key > -1)
	{
		BOOL shifted = [self isIntellivisionKeyShiftedForKeycode:keyCode];

		[self setIntellivisionKey:key isDown:NO isShifted:shifted];
	}
}

@end
