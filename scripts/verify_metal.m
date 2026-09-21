#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#include <sys/sysctl.h>

// Host-only smoke probe. It never initializes MLX's exit-on-error handler and
// never mutates the signed app or downloads model weights.
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSURL *resources = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        NSData *manifestData = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:@"metal-build.json"]];
        NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error] : nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!manifest || !device) {
            fprintf(stderr, "Metal verification: missing manifest or Metal device\n");
            return 1;
        }
        NSMutableArray *checked = [NSMutableArray array];
        for (NSDictionary *entry in manifest[@"libraries"]) {
            NSString *path = entry[@"path"];
            NSURL *url = [resources URLByAppendingPathComponent:path];
            error = nil;
            NSUInteger functions = 0;
            if ([path hasPrefix:@"mlx-swift_Cmlx.bundle/"]) {
                id<MTLLibrary> library = [device newLibraryWithURL:url error:&error];
                functions = library.functionNames.count;
                if (!library || !functions) {
                    fprintf(stderr, "Cannot load %s: %s\n", path.UTF8String, error.description.UTF8String);
                    return 1;
                }
            } else {
                NSData *data = [NSData dataWithContentsOfURL:url];
                NSArray<NSString *> *names = data ? [CIKernel kernelNamesFromMetalLibraryData:data] : nil;
                functions = names.count;
                if (!functions) {
                    fprintf(stderr, "No Core Image kernels in %s\n", path.UTF8String);
                    return 1;
                }
                for (NSString *name in names) {
                    if (![CIKernel kernelWithFunctionName:name fromMetalLibraryData:data error:&error]) {
                        fprintf(stderr, "Cannot load CI kernel %s: %s\n", name.UTF8String, error.description.UTF8String);
                        return 1;
                    }
                }
            }
            [checked addObject:@{@"path": path, @"functions": @(functions)}];
        }
        uint64_t memory = 0;
        size_t size = sizeof(memory);
        sysctlbyname("hw.memsize", &memory, &size, NULL, 0);
        NSDictionary *report = @{
            @"scope": @"Shader loading on this machine only; inference and other devices require real-device tests",
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"gpu": device.name,
            @"memory_bytes": @(memory),
            @"libraries": checked
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        fwrite(json.bytes, 1, json.length, stdout);
        puts("");
        return 0;
    }
}
