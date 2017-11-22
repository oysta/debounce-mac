// compile and run from the commandline with:
//    clang -fobjc-arc -framework Cocoa  ./debounce.m  -o debounce
//    sudo ./debounce

/*
 * Keyboard debouncer, main audience is users of flaky mechanical
 * keyboards.  Script heavily inspired by Brad Allred's answer on
 * StackOverflow:
 * <http://stackoverflow.com/questions/19646108/modify-keydown-output>.
 */

#import <Foundation/Foundation.h>
#import <AppKit/NSEvent.h>

#define DEBOUNCE_DELAY 100
#define SYNTHETIC_KB_ID 666

typedef CFMachPortRef EventTap;

@interface KeyStroke : NSObject

@property UInt16 keyCode;
@property NSTimeInterval keyTime;

@end

@implementation KeyStroke

@synthesize keyCode;
@synthesize keyTime;

@end

@interface KeyChanger : NSObject
{
@private
  EventTap _eventTap;
  CFRunLoopSourceRef _runLoopSource;
  NSMutableArray *keyQueue;
}

@property NSMutableArray *keyQueue;

- (BOOL)hasBounced:(NSEvent *)event;

@end

CGEventRef _tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, KeyChanger* listener);

@implementation KeyChanger

@synthesize keyQueue;

- (id)init
{
    if (self = [super init]) {
        self.keyQueue = [NSMutableArray new];
    }
    return self;
}

- (BOOL)tapEvents
{
    if (!_eventTap) {
        NSLog(@"Initializing an event tap.");

        _eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGTailAppendEventTap,
                                     kCGEventTapOptionDefault,
                                     CGEventMaskBit(kCGEventKeyDown),
                                     (CGEventTapCallBack)_tapCallback,
                                     (__bridge void *)(self));
        if (!_eventTap) {
            NSLog(@"Unable to create event tap.  Must run as root or add privileges for assistive devices to this app.");
            return NO;
        }
    }
    CGEventTapEnable(_eventTap, TRUE);

    return [self isTapActive];
}

- (BOOL)isTapActive
{
    return CGEventTapIsEnabled(_eventTap);
}

- (void)listen
{
    if (!_runLoopSource) {
        if (_eventTap) { // Don't use [self tapActive]
            _runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                           _eventTap, 0);
            // Add to the current run loop.
            CFRunLoopAddSource(CFRunLoopGetCurrent(), _runLoopSource,
                               kCFRunLoopCommonModes);

            NSLog(@"Registering event tap as run loop source.");
            CFRunLoopRun();
        }
        else {
            NSLog(@"No Event tap in place!  You will need to call listen after tapEvents to get events.");
        }
    }
}

- (BOOL)hasBounced:(NSEvent *)event
{
    NSMutableArray *staleEvents = [NSMutableArray new];

    BOOL bounce = NO;

    for (KeyStroke *previous in self.keyQueue) {
        NSTimeInterval time = (event.timestamp - previous.keyTime);
        int64_t timeMs = time * 1000;

        if (timeMs > DEBOUNCE_DELAY) {
            [staleEvents addObject: previous];
        }
        else if (previous.keyCode == event.keyCode) {
            NSLog(@"BOUNCE detected!!!  Character: %@",
                  event.characters);
            NSLog(@"Time between keys: %lldms (limit <%dms)",
                  timeMs,
                  DEBOUNCE_DELAY);
            bounce = YES;
            break;
        }
    }

    [self.keyQueue removeObjectsInArray: staleEvents];
    return bounce;
}

- (CGEventRef)processEvent:(CGEventRef)cgEvent
{
    NSEvent* event = [NSEvent eventWithCGEvent:cgEvent];

    int64_t keyboard_id = CGEventGetIntegerValueField(cgEvent, kCGKeyboardEventKeyboardType);

    if (keyboard_id == SYNTHETIC_KB_ID || event.isARepeat) {
        return cgEvent;
    }

    if ([self hasBounced: event]) {
        // Cancel keypress event
        return NULL;
    }

    KeyStroke *keyStroke = [KeyStroke new];
    keyStroke.keyCode = event.keyCode;
    keyStroke.keyTime = event.timestamp;
    [self.keyQueue addObject: keyStroke];

    return cgEvent;
}

- (void)dealloc
{
    if (_runLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopCommonModes);
        CFRelease(_runLoopSource);
    }
    if (_eventTap) {
        // Kill the event tap
        CGEventTapEnable(_eventTap, FALSE);
        CFRelease(_eventTap);
    }
}

@end

CGEventRef _tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, KeyChanger* listener) {
    // Do not make the NSEvent here.
    // NSEvent will throw an exception if we try to make an event from the tap timeout type
    @autoreleasepool {
        if (type == kCGEventTapDisabledByTimeout) {
            NSLog(@"event tap has timed out, re-enabling tap");
            [listener tapEvents];
            return nil;
        }
        if (type != kCGEventTapDisabledByUserInput) {
            return [listener processEvent:event];
        }
    }
    return event;
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        KeyChanger* keyChanger = [KeyChanger new];
        [keyChanger tapEvents];
        [keyChanger listen]; // This is a blocking call.
    }
    return 0;
}
