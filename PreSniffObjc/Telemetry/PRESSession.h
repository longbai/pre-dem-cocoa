#import "PRESTelemetryObject.h"

@interface PRESSession : PRESTelemetryObject <NSCoding>

@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *isFirst;
@property (nonatomic, copy) NSString *isNew;

@end
