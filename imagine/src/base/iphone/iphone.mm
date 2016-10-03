#define thisModuleName "base:iphone"

#import "MainApp.h"
#import "EAGLView.h"
#import <dlfcn.h>
#import <unistd.h>

#include <base/interface.h>
#include <base/common/funcs.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGLDrawable.h>
#import <Foundation/NSPathUtilities.h>

#import "AtariDuoGamePad.h"

#ifdef CONFIG_INPUT
	#include "input.h"
#endif

#ifdef CONFIG_BASE_IOS_ICADE
	#include "ICadeHelper.hh"
#endif

namespace Base
{
const char *appPath = 0;
static int pointScale = 1;

static UIWindow *window, *externalWindow = 0;
static EAGLView *glView;
static EAGLContext *mainContext;
static MainApp *mainApp;
static CADisplayLink *displayLink = 0;
static BOOL displayLinkActive = NO;
static bool isIPad = 0;
static bool usingiOS4 = 0;

#ifdef CONFIG_BASE_IOS_ICADE
static ICadeHelper iCade = { nil };

void ios_setICadeActive(uint active)
{
	iCade.init(glView);
	iCade.setActive(active);
}

uint ios_iCadeActive()
{
	return iCade.isActive();
}
#endif

#if defined(IPHONE_MSG_COMPOSE) || defined(IPHONE_IMG_PICKER)
	static UIViewController *viewCtrl;
#endif

#ifdef CONFIG_INPUT
	#ifdef IPHONE_VKEYBOARD
		//static UITextField *vkbdField;
		static UITextView *vkbdField;
		static uchar inVKeyboard = 0;
		static InputTextCallback vKeyboardTextCallback = NULL;
		static void *vKeyboardTextCallbackUserPtr = NULL;
	#endif
#endif

#ifdef IPHONE_IMG_PICKER
	static UIImagePickerController* imagePickerController;
	static IPhoneImgPickerCallback imgPickCallback = NULL;
	static void *imgPickUserPtr = NULL;
	static NSData *imgPickData[2];
	static uchar imgPickDataElements = 0;
	#include "imagePicker.h"
#endif

#ifdef IPHONE_MSG_COMPOSE
	static MFMailComposeViewController *composeController;
	#include "mailCompose.h"
#endif

#ifdef IPHONE_GAMEKIT
	#include "gameKit.h"
#endif

#ifdef GREYSTRIPE
    #include "greystripe.h"
#endif

static const int USE_DEPTH_BUFFER = 0;
static int openglViewIsInit = 0;

static NSTimer *mainTimer = 0;
static TimerCallbackFunc timerCallbackFunc = 0;
static void *timerCallbackFuncCtx = 0;

void setTimerCallback(TimerCallbackFunc f, void *ctx, int ms)
{
	if(timerCallbackFunc)
	{
		logMsg("canceling callback");
		timerCallbackFunc = 0;
		if(mainTimer)
		{
			[mainTimer invalidate];
			//[mainTimer release];
			mainTimer = 0;
		}
	}
	if(!f)
		return;
	logMsg("setting callback to run in %d ms", ms);
	timerCallbackFunc = f;
	timerCallbackFuncCtx = ctx;
	mainTimer = [NSTimer scheduledTimerWithTimeInterval: (float)ms/1000. target:mainApp selector:@selector(timerCallback:) userInfo:nil repeats: NO];
}

bool isInputDevPresent(uint type)
{
	return 0;
}

void openGLUpdateScreen()
{
	//logMsg("doing swap");
	//glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[Base::mainContext presentRenderbuffer:GL_RENDERBUFFER_OES];
}

void startAnimation()
{
	if(!Base::displayLinkActive)
	{
		displayLink.paused = NO; 
		Base::displayLinkActive = YES;
	}
}

void stopAnimation()
{
	if(Base::displayLinkActive)
	{
		displayLink.paused = YES;
		Base::displayLinkActive = NO;
	}
}

uint appState = APP_RUNNING;

}

// A class extension to declare private methods
@interface EAGLView ()

@property (nonatomic, retain) EAGLContext *context;

- (BOOL) createFramebuffer;
- (void) destroyFramebuffer;

@property (nonatomic, strong) AtariDuoGamePad *atariDuoPad;
@property (nonatomic, assign) uint8_t duoPreviousState;

@end

@implementation EAGLView

@synthesize context;

// Implement this to override the default layer class (which is [CALayer class]).
// We do this so that our view will be backed by a layer that is capable of OpenGL ES rendering.
+ (Class)layerClass
{
	return [CAEAGLLayer class];
}

-(id)initGLES
{
	// Get our backing layer
	CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
	
	eaglLayer.opaque = YES;
	//eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
	//	[NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
	//	kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat, nil];

	context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
	assert(context);
	int ret = [EAGLContext setCurrentContext:context];
	assert(ret);
	/*if (!context || ![EAGLContext setCurrentContext:context])
	{
		[self release];
		return nil;
	}*/
	Base::mainContext = context;
	
	Base::displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawView)];
	//displayLink.paused = YES;
	Base::displayLinkActive = YES;
	[Base::displayLink setFrameInterval:1];
	[Base::displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

	return self;
}

#ifdef CONFIG_BASE_IPHONE_NIB
// Init from NIB
- (id)initWithCoder:(NSCoder*)coder
{
	if ((self = [super initWithCoder:coder]))
	{
		self = [self initGLES];
	}
	return self;
}
#endif

// Init from code
-(id)initWithFrame:(CGRect)frame
{
	logMsg("entered initWithFrame");
	if((self = [super initWithFrame:frame]))
	{
		self = [self initGLES];
        _atariDuoPad = [[AtariDuoGamePad alloc] init];
        [self configureAtariGamepadHandler];
	}
	logMsg("exiting initWithFrame");
	return self;
}

- (void)drawView
{
	/*TimeSys now;
	now.setTimeNow();
	logMsg("frame time stamp %f, duration %f, now %f", displayLink.timestamp, displayLink.duration, (float)now);*/
	//[EAGLContext setCurrentContext:context];
	//glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
	if(unlikely(!Base::displayLinkActive))
		return;

	//logMsg("screen update");
	Base::runEngine();
	if(!Base::gfxUpdate)
	{
		Base::stopAnimation();
	}
}


- (void)layoutSubviews
{
	logMsg("entered layoutSubviews");
	[EAGLContext setCurrentContext:context];
	[self destroyFramebuffer];
	[self createFramebuffer];
	Base::engineInit();
	Base::setAutoOrientation(1);
	[self drawView];
	logMsg("exiting layoutSubviews");
}


- (BOOL)createFramebuffer
{
    glGenFramebuffersOES(1, &viewFramebuffer);
	glGenRenderbuffersOES(1, &viewRenderbuffer);

	glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
	glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer*)self.layer];
	glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, viewRenderbuffer);

	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);

	if(Base::USE_DEPTH_BUFFER)
	{
		glGenRenderbuffersOES(1, &depthRenderbuffer);
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthRenderbuffer);
		glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES, backingWidth, backingHeight);
		glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthRenderbuffer);
	}

	if(glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES)
	{
		logMsg("failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
		return NO;
	}
	
	Base::openglViewIsInit = 1;
	return YES;
}


- (void)destroyFramebuffer
{
	glDeleteFramebuffersOES(1, &viewFramebuffer);
	viewFramebuffer = 0;
	glDeleteRenderbuffersOES(1, &viewRenderbuffer);
	viewRenderbuffer = 0;

	if(depthRenderbuffer)
	{
		glDeleteRenderbuffersOES(1, &depthRenderbuffer);
		depthRenderbuffer = 0;
	}
	
	Base::openglViewIsInit = 0;
}

- (void)dealloc
{
	if ([EAGLContext currentContext] == context)
	{
		[EAGLContext setCurrentContext:nil];
	}

	[context release];
	[super dealloc];
}

#ifdef CONFIG_INPUT

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	#if defined(IPHONE_VKEYBOARD)
	if(inVKeyboard)
	{
		input_finishKeyboardInput();
		return;
	}
	#endif
	
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find a free touch element
		{
			if(Input::activeTouch[i] == NULL)
			{
				Input::activeTouch[i] = touch;
				var_copy(p, &Input::m[i]);
				CGPoint startTouchPosition = [touch locationInView:self];
				pointerPos(startTouchPosition.x * pointScale, startTouchPosition.y * pointScale, &p->x, &p->y);
				p->inWin = 1;
				Input::dragStateArr[i].pointerEvent(Input::Pointer::LBUTTON, INPUT_PUSHED, p->x, p->y);
				callSafe(Input::onInputEventHandler, Input::onInputEventHandlerCtx, InputEvent(i, InputEvent::DEV_POINTER, Input::Pointer::LBUTTON, INPUT_PUSHED, p->x, p->y));
				break;
			}
		}
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find the touch element
		{
			if(Input::activeTouch[i] == touch)
			{
				var_copy(p, &Input::m[i]);
				CGPoint currentTouchPosition = [touch locationInView:self];
				pointerPos(currentTouchPosition.x * pointScale, currentTouchPosition.y * pointScale, &p->x, &p->y);
				Input::dragStateArr[i].pointerEvent(Input::Pointer::LBUTTON, INPUT_MOVED, p->x, p->y);
				callSafe(Input::onInputEventHandler, Input::onInputEventHandlerCtx, InputEvent(i, InputEvent::DEV_POINTER, Input::Pointer::LBUTTON, INPUT_MOVED, p->x, p->y));
				break;
			}
		}
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find the touch element
		{
			if(Input::activeTouch[i] == touch)
			{
				Input::activeTouch[i] = nil;
				var_copy(p, &Input::m[i]);
				p->inWin = 0;
				CGPoint currentTouchPosition = [touch locationInView:self];
				pointerPos(currentTouchPosition.x * pointScale, currentTouchPosition.y * pointScale, &p->x, &p->y);
				Input::dragStateArr[i].pointerEvent(Input::Pointer::LBUTTON, INPUT_RELEASED, p->x, p->y);
				callSafe(Input::onInputEventHandler, Input::onInputEventHandlerCtx, InputEvent(i, InputEvent::DEV_POINTER, Input::Pointer::LBUTTON, INPUT_RELEASED, p->x, p->y));
				break;
			}
		}
	}
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	[self touchesEnded:touches withEvent:event];
}

#if defined(CONFIG_BASE_IOS_KEY_INPUT) || defined(CONFIG_BASE_IOS_ICADE)
- (BOOL)canBecomeFirstResponder { return YES; }

- (BOOL)hasText { return NO; }

- (void)insertText:(NSString *)text
{
	#ifdef CONFIG_BASE_IOS_ICADE
	if(Base::iCade.isActive())
		Base::iCade.insertText(text);
	#endif
	//logMsg("got text %s", [text cStringUsingEncoding: NSUTF8StringEncoding]);
}

- (void)deleteBackward { }

#ifdef CONFIG_BASE_IOS_ICADE
- (UIView*)inputView
{
	return Base::iCade.dummyInputView;
}

#pragma mark - AtariGamePad
- (void)configureAtariGamepadHandler {
    self.atariDuoPad.handler = ^(uint8_t state) {
        if(!Base::iCade.isActive()) {
            return;
        } else if (state == self.duoPreviousState) {
            // If the state is the same, let the current state run
            return;
        } else if (!self.duoPreviousState) {
            // this is the first time running. just do whatever the state is
            [self executeState:state];
            self.duoPreviousState = state;
        } else { // Every 1->0 needs to be undone and every 0->1 needs to execute
            // If the state is different, we need to send the "up" state to everything that went from 1 to 0.
            uint8_t stateToUndo = self.duoPreviousState & (~state);
            [self undoState:stateToUndo];
            
            // Execute new buttons that have become active
            uint8_t stateToExecute = ~self.duoPreviousState & state;
            [self executeState:stateToExecute];
            
            // Now the current state becomes the last state
            self.duoPreviousState = state;
        }
    };
}

- (void)executeState:(uint8_t)state
{
    if (state & ATARI_BUTT_Y) {
        [self insertText:@"i"];
    }
    if (state & ATARI_BUTT_X) {
        [self insertText:@"k"];
    }
    if (state & ATARI_BUTT_B) {
        [self insertText:@"o"];
    }
    if (state & ATARI_BUTT_A) {
        [self insertText:@"l"];
    }
    if (state & ATARI_RIGHT) {
        [self insertText:@"d"];
    }
    if (state & ATARI_LEFT) {
        [self insertText:@"a"];
    }
    if (state & ATARI_DOWN) {
        [self insertText:@"x"];
    }
    if (state & ATARI_UP) {
        [self insertText:@"w"];
    }
}

- (void)undoState:(uint8_t)state
{
    if (state & ATARI_BUTT_Y) {
        [self insertText:@"m"];
    }
    if (state & ATARI_BUTT_X) {
        [self insertText:@"p"];
    }
    if (state & ATARI_BUTT_B) {
        [self insertText:@"g"];
    }
    if (state & ATARI_BUTT_A) {
        [self insertText:@"v"];
    }
    if (state & ATARI_RIGHT) {
        [self insertText:@"c"];
    }
    if (state & ATARI_LEFT) {
        [self insertText:@"q"];
    }
    if (state & ATARI_DOWN) {
        [self insertText:@"z"];
    }
    if (state & ATARI_UP) {
        [self insertText:@"e"];
    }
}

#endif
#endif // defined(CONFIG_BASE_IOS_KEY_INPUT) || defined(CONFIG_BASE_IOS_ICADE)

#endif

@end

@implementation MainApp

#if defined(CONFIG_INPUT) && defined(IPHONE_VKEYBOARD)
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text
{
	if (textView.text.length >= 127 && range.length == 0)
		return NO;
	return YES;
}
#endif

/*- (void) screenDidConnect:(NSNotification *)aNotification
{
	logMsg("New screen connected");
	UIScreen *screen = [aNotification object];
	UIScreenMode *mode = [[screen availibleModes] lastObject];
	screen.currentMode = mode;
	if(!externalWindow)
	{
		externalWindow = [UIWindow alloc];
	}
	CGRect rect = CGRectMake(0, 0, mode.size.width, mode.size.height);
	[externalWindow initWithFrame:rect];
	externalWindow.screen = screen;
	[externalWindow makeKeyAndVisible];
}
 
- (void) screenDidDisconnect:(NSNotification *)aNotification
{
	logMsg("Screen dis-connected");
}
 
- (void) screenModeDidChange:(NSNotification *)aNotification
{
	UIScreen *screen = [aNotification object];
	logMsg("Screen-mode change"); // [screen currentMode]
}*/

static uint iOSOrientationToGfx(UIDeviceOrientation orientation)
{
	switch(orientation)
	{
		case UIDeviceOrientationPortrait: return Gfx::VIEW_ROTATE_0;
		case UIDeviceOrientationLandscapeLeft: return Gfx::VIEW_ROTATE_90;
		case UIDeviceOrientationLandscapeRight: return Gfx::VIEW_ROTATE_270;
		case UIDeviceOrientationPortraitUpsideDown: return Gfx::VIEW_ROTATE_180;
		default : return 255; // TODO: handle Face-up/down
	}
}

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
	using namespace Base;
	NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
	#ifndef NDEBUG
	logMsg("in applicationDidFinishLaunching(), UUID %s", [[[UIDevice currentDevice] uniqueIdentifier] cStringUsingEncoding: NSASCIIStringEncoding]);
	logMsg("iOS version %s", [currSysVer cStringUsingEncoding: NSASCIIStringEncoding]);
	#endif
	mainApp = self;
	
	NSString *reqSysVer = @"4.0";
	if ([currSysVer compare:reqSysVer options:NSNumericSearch] != NSOrderedAscending)
	{
		//logMsg("enabling iOS 4 features");
		usingiOS4 = 1;
	}
	
	/*if ([currSysVer compare:@"3.2" options:NSNumericSearch] != NSOrderedAscending)
	{
		logMsg("enabling iOS 3.2 external display features");
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver:self selector:@selector(screenDidConnect:) name:UIScreenDidConnectNotification object:nil];
		[center addObserver:self selector:@selector(screenDidDisconnect:) name:UIScreenDidDisconnectNotification object:nil];
		[center addObserver:self selector:@selector(screenModeDidChange:) name:UIScreenModeDidChangeNotification object:nil];
	}*/
	
	// TODO: get real DPI if possible
	Gfx::viewMMWidth_ = 50, Gfx::viewMMHeight_ = 75;
	#if !defined(__ARM_ARCH_6K__) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= 30200)
	logMsg("testing for iPad");
	if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
	{
    	Gfx::viewMMWidth_ = 148, Gfx::viewMMHeight_ = 197;
		isIPad = 1;
		logMsg("running on iPad");
		
		/*rotateView = preferedOrientation = iOSOrientationToGfx([[UIDevice currentDevice] orientation]);
		logMsg("started in %s orientation", Gfx::orientationName(rotateView));
		#ifdef CONFIG_INPUT
			Gfx::configureInputForOrientation();
		#endif*/
	}
	#endif

	CGRect rect = [[UIScreen mainScreen] bounds];
	newXSize = rect.size.width;
	newYSize = rect.size.height;
	// Create a full-screen window
	window = [[UIWindow alloc] initWithFrame:rect];
	
	#if defined(CONFIG_INPUT) && defined(IPHONE_VKEYBOARD)
		// init input text field
		//vkbdField = [ [ UITextField alloc ] initWithFrame: CGRectMake(8, 200, 320-16, 48) ];
		vkbdField = [ [ UITextView alloc ] initWithFrame: CGRectMake(12, 24, 286, 24*4) ];
		//vkbdField.adjustsFontSizeToFitWidth = YES;
		vkbdField.textColor = [UIColor blackColor];
		vkbdField.font = [UIFont systemFontOfSize:16.0];
		//vkbdField.placeholder = @"";
		vkbdField.backgroundColor = [UIColor whiteColor];
		//vkbdField.borderStyle = UITextBorderStyleBezel;
		vkbdField.autocorrectionType = UITextAutocorrectionTypeNo; // no auto correction support
		vkbdField.autocapitalizationType = UITextAutocapitalizationTypeNone; // no auto capitalization support
		vkbdField.textAlignment = UITextAlignmentLeft;
		vkbdField.keyboardType = UIKeyboardTypeASCIICapable; //UIKeyboardTypeDefault;
		//vkbdField.returnKeyType = UIReturnKeyDone;
		//vkbdField.keyboardAppearance = UIKeyboardAppearanceAlert;
		//vkbdField.tag = 0;
		vkbdField.delegate = self;
		//vkbdField.clearButtonMode = UITextFieldViewModeNever; // no clear 'x' button to the right
		vkbdField.text = @"";
		vkbdField.enablesReturnKeyAutomatically = YES;
		//[ vkbdField setEnabled: YES ];
		logMsg("init vkeyboard");
	#endif
	
	#ifdef GREYSTRIPE
	initGS(self);
	#endif
	
	// Create the OpenGL ES view and add it to the window
	glView = [[EAGLView alloc] initWithFrame:rect];
	#if !defined(__ARM_ARCH_6K__)
	if(usingiOS4)
	{
		logMsg("testing for Retina Display");
		if([UIScreen mainScreen].scale == 2.0)
		{
			logMsg("running on Retina Display");
			glView.layer.contentsScale = 2.0;
			pointScale = 2;
			newXSize *= 2;
			newYSize *= 2;
	    }
	}
    #endif
    
    /*{
    	mach_port_t mp;
	    IOMasterPort(MACH_PORT_NULL,&mp);
	    CFMutableDictionaryRef bt_matching = IOServiceNameMatching("bluetooth");
	    mach_port_t bt_service = IOServiceGetMatchingService(mp, bt_matching);
	
	    // local-mac-address
	    bd_addr_t address;
	    CFTypeRef local_mac_address_ref = IORegistryEntrySearchCFProperty(bt_service,"IODeviceTree",CFSTR("local-mac-address"), kCFAllocatorDefault, 1);
	    CFDataGetBytes(local_mac_address_ref,CFRangeMake(0,CFDataGetLength(local_mac_address_ref)),addr); // buffer needs to be unsigned char
	
	    IOObjectRelease(bt_service);
	    
	    // dump info
	    char bd_addr_to_str_buffer[6*3];
	    sprintf(bd_addr_to_str_buffer, "%02x:%02x:%02x:%02x:%02x:%02x", addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
	    log_info("local-mac-address: %s\n", bd_addr_to_str_buffer);
    }*/
    
    /*iCadeReaderView *control = [[iCadeReaderView alloc] initWithFrame:CGRectZero];
    [window addSubview:control];
    control.active = YES;
    [control release];*/
    
    glView.multipleTouchEnabled = YES;
    UIViewController *rootViewController = [[UIViewController alloc] init];
    rootViewController.view = glView;
	[window setRootViewController:rootViewController];
	[glView release];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
	
	[UIApplication sharedApplication].idleTimerDisabled = YES;

	[window makeKeyAndVisible];
	#if defined(IPHONE_MSG_COMPOSE) || defined(IPHONE_IMG_PICKER)
	viewCtrl = [[UIViewController alloc] init];
	[viewCtrl setView: glView];
	#endif
	logMsg("exiting applicationDidFinishLaunching");
}

- (void)orientationChanged:(NSNotification *)notification
{
	uint o = iOSOrientationToGfx([[UIDevice currentDevice] orientation]);
	if(o == 255)
		return;
	if(o != Gfx::VIEW_ROTATE_180)
	{
		logMsg("new orientation %s", Gfx::orientationName(o));
		Gfx::preferedOrientation = o;
		Gfx::setOrientation(Gfx::preferedOrientation);
	}
}

- (void)applicationWillResignActive:(UIApplication *)application
{
	logMsg("resign active");
	Base::stopAnimation();
	glFinish();
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	using namespace Base;
	logMsg("became active");
	Base::appState = APP_RUNNING;
	if(Base::displayLink)
		Base::startAnimation();
	callSafe(Base::onAppResumeHandler, Base::onAppResumeHandlerCtx, 1);
	#ifdef CONFIG_BASE_IOS_ICADE
	iCade.didBecomeActive();
	#endif
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	using namespace Base;
	logMsg("app exiting");
	//Base::stopAnimation();
	Base::appState = APP_EXITING;
	callSafe(Base::onAppExitHandler, Base::onAppExitHandlerCtx, 0);
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	using namespace Base;
	logMsg("entering background");
	appState = APP_PAUSED;
	Base::stopAnimation();
	callSafe(Base::onAppExitHandler, Base::onAppExitHandlerCtx, 1);
	#ifdef CONFIG_BASE_IOS_ICADE
	iCade.didEnterBackground();
	#endif
	glFinish();
}

- (void)timerCallback:(NSTimer*)timer
{
	using namespace Base;
	if(timerCallbackFunc)
	{
		logMsg("running callback");
		timerCallbackFunc(timerCallbackFuncCtx);
		timerCallbackFunc = 0;
	}
}

- (void)dealloc
{
	[Base::window release];
	//[glView release]; // retained in window
	[super dealloc];
}

#if defined(CONFIG_INPUT) && defined(IPHONE_VKEYBOARD)

/*- (BOOL) textFieldShouldReturn:(UITextField *)textField
{
	[textField resignFirstResponder];
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
	[vkbdField removeFromSuperview];
	NSString *text = vkbdField.text;
	//logMsg("calling text callback");
	vKeyboardTextCallback(vKeyboardTextCallbackUserPtr, [text cStringUsingEncoding: NSASCIIStringEncoding]);
	vkbdField.text = @"";
	inVKeyboard = 0;
}*/

#endif

@end

namespace Base
{

void ios_setVideoInterval(uint interval)
{
	logMsg("setting frame interval %d", (int)interval);
	assert(interval >= 1);
	[Base::displayLink setFrameInterval:interval];
}

void statusBarHidden(uint hidden)
{
	[[UIApplication sharedApplication] setStatusBarHidden: hidden ? YES : NO];
}

void statusBarOrientation(uint o)
{
	switch(o)
	{
		bcase Gfx::VIEW_ROTATE_0:
			[[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationPortrait animated:NO];
		bcase Gfx::VIEW_ROTATE_270:
			[[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft animated:NO];
		bcase Gfx::VIEW_ROTATE_90:
			[[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeRight animated:NO];
		bcase Gfx::VIEW_ROTATE_180:
			[[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationPortraitUpsideDown animated:NO];
	}
}

static bool autoOrientationState = 0; // Turned on in applicationDidFinishLaunching

void setAutoOrientation(bool on)
{
	if(autoOrientationState == on)
		return;
	autoOrientationState = on;
	if(on)
		[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
	else
	{
		Gfx::preferedOrientation = Gfx::rotateView;
		[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
	}
}

void exitVal(int returnVal)
{
	appState = APP_EXITING;
	callSafe(onAppExitHandler, onAppExitHandlerCtx, 0);
	::exit(returnVal);
}
void abort() { ::abort(); }

void displayNeedsUpdate()
{
	generic_displayNeedsUpdate();
	if(appState == APP_RUNNING && Base::displayLinkActive == NO)
	{
		Base::startAnimation();
	}
}

void openURL(const char *url)
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:
		[NSString stringWithCString:url encoding:NSASCIIStringEncoding]]];
}

static const char *docPath = 0;

const char *documentsPath()
{
	if(!docPath)
	{
		#ifdef CONFIG_BASE_IOS_JB
			return "/User/Library/Preferences";
		#else
			NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
			NSString *documentsDirectory = [paths objectAtIndex:0];
			docPath = strdup([documentsDirectory cStringUsingEncoding: NSASCIIStringEncoding]);
		#endif
	}
	return docPath;
}

const char *storagePath()
{
	#ifdef CONFIG_BASE_IOS_JB
		return "/User/Media";
	#else
		return documentsPath();
	#endif
}

int runningDeviceType()
{
	return isIPad ? DEV_TYPE_IPAD : DEV_TYPE_GENERIC;
}

#ifdef CONFIG_BASE_IOS_SETUID

uid_t realUID = 0, effectiveUID = 0;
static void setupUID()
{
	realUID = getuid();
	effectiveUID = geteuid();
	seteuid(realUID);
}

void setUIDReal()
{
	seteuid(Base::realUID);
}

bool setUIDEffective()
{
	return seteuid(Base::effectiveUID) == 0;
}

#endif

}

int main(int argc, char *argv[])
{
	using namespace Base;
	#ifdef CONFIG_BASE_IOS_SETUID
	setupUID();
	#endif
	
	doOrExit(logger_init());
	
	#ifdef CONFIG_BASE_IOS_SETUID
	logMsg("real UID %d, effective UID %d", realUID, effectiveUID);
	if(access("/Library/MobileSubstrate/DynamicLibraries/Backgrounder.dylib", F_OK) == 0)
	{
		logMsg("manually loading Backgrounder.dylib");
		dlopen("/Library/MobileSubstrate/DynamicLibraries/Backgrounder.dylib", RTLD_LAZY | RTLD_GLOBAL);
	}
	#endif

	#ifdef CONFIG_FS
	Fs::changeToAppDir(argv[0]);
	#endif

	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	int retVal = UIApplicationMain(argc, argv, nil, @"MainApp");
	[pool release];
	return retVal;
}

#undef thisModuleName
