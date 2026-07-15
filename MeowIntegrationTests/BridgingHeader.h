// Bridging header for MeowIntegrationTests.
//
// Superset of App/Sources/BridgingHeader.h: the same C FFI surface the app
// bridges, plus the production PacketTunnel ObjC sources that project.yml
// compiles directly into this test bundle (extension binaries are not
// linkable, so shared-source membership is how extension-internal code gets
// exercised from unit tests).
#import "meow_core.h"
#import "MWCnBypass.h"
#import "MWTunnelSettings.h"
