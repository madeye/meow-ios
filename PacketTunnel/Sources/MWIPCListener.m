#import "MWIPCListener.h"
#import "MWDarwinBridge.h"
#import "MWSharedStore.h"

@implementation MWIPCListener {
    MWIntentHandler _handler;
    MWDarwinObserver *_observer;
}

- (instancetype)initWithHandler:(MWIntentHandler)handler {
    self = [super init];
    if (self) { _handler = handler; }
    return self;
}

- (void)start {
    MWIntentHandler handler = _handler;
    _observer = [MWDarwinBridge observe:MWNotificationCommand handler:^{
        NSDictionary *intent = [MWSharedStore takeIntent];
        if (intent) handler(intent);
    }];
}

- (void)stop {
    if (_observer) {
        [MWDarwinBridge remove:_observer];
        _observer = nil;
    }
}

@end
