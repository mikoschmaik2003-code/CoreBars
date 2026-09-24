#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/processor_info.h>
#import <mach/vm_statistics.h>
#import <IOKit/IOKitLib.h>
#import <libproc.h>
#import <math.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <unistd.h>

static double CBClamp(double value, double minimum, double maximum) {
    return MIN(maximum, MAX(minimum, value));
}

static double CBNormalizeFrequencyMHz(double value) {
    if (!isfinite(value) || value <= 0) return NAN;
    if (value > 1000000) return value / 1000000.0;
    if (value > 10000) return value / 1000.0;
    return value;
}

static double CBMaxNumberInObject(id object) {
    double maxValue = NAN;
    if ([object isKindOfClass:NSNumber.class]) {
        return ((NSNumber *)object).doubleValue;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)object) {
            double value = CBMaxNumberInObject(item);
            if (isfinite(value)) maxValue = isfinite(maxValue) ? MAX(maxValue, value) : value;
        }
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id valueObject in ((NSDictionary *)object).allValues) {
            double value = CBMaxNumberInObject(valueObject);
            if (isfinite(value)) maxValue = isfinite(maxValue) ? MAX(maxValue, value) : value;
        }
    }
    return maxValue;
}

static NSString *CBThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"normal";
        case NSProcessInfoThermalStateFair: return @"warm";
        case NSProcessInfoThermalStateSerious: return @"heiß";
        case NSProcessInfoThermalStateCritical: return @"kritisch";
    }
    return @"unbekannt";
}

static int64_t CBSignedBatteryInteger(id object) {
    if (![object isKindOfClass:NSNumber.class]) return 0;
    NSNumber *number = object;
    uint64_t raw = number.unsignedLongLongValue;
    if (raw > INT64_MAX) return (int64_t)(raw - UINT64_MAX - 1);
    return (int64_t)raw;
}

static NSString *CBShortByteText(uint64_t bytes) {
    double gib = (double)bytes / 1024.0 / 1024.0 / 1024.0;
    if (gib >= 100) return [NSString stringWithFormat:@"%.0fG", gib];
    if (gib >= 10) return [NSString stringWithFormat:@"%.1fG", gib];
    double mib = (double)bytes / 1024.0 / 1024.0;
    return [NSString stringWithFormat:@"%.0fM", mib];
}

static NSString *CBRateText(double bytesPerSecond) {
    if (!isfinite(bytesPerSecond) || bytesPerSecond < 1024) return @"0 KB/s";
    double mib = bytesPerSecond / 1024.0 / 1024.0;
    if (mib >= 1) return [NSString stringWithFormat:@"%.1f MB/s", mib];
    return [NSString stringWithFormat:@"%.0f KB/s", bytesPerSecond / 1024.0];
}

static NSString *CBCompactRateText(double bytesPerSecond) {
    if (!isfinite(bytesPerSecond) || bytesPerSecond < 1024 * 1024) return @"0M";
    double mib = bytesPerSecond / 1024.0 / 1024.0;
    return mib >= 100 ? [NSString stringWithFormat:@"%.0fM", mib] : [NSString stringWithFormat:@"%.1fM", mib];
}

static NSString *CBCompactMbitRateText(double bytesPerSecond) {
    if (!isfinite(bytesPerSecond) || bytesPerSecond <= 0) return @"00/Mbits";
    double mbits = bytesPerSecond * 8.0 / 1000.0 / 1000.0;
    if (mbits < 10) return [NSString stringWithFormat:@"0%.0f/Mbits", floor(mbits)];
    return [NSString stringWithFormat:@"%.0f/Mbits", floor(mbits)];
}

static NSString *CBMbitRateText(double bytesPerSecond) {
    if (!isfinite(bytesPerSecond) || bytesPerSecond <= 0) return @"0 Mbit/s";
    return [NSString stringWithFormat:@"%.1f Mbit/s", bytesPerSecond * 8.0 / 1000.0 / 1000.0];
}

static NSString *CBDrainStatus(NSInteger level) {
    if (level <= 0) return @"normal";
    if (level == 1) return @"erhöht";
    return @"hoch";
}

static NSString *CBMemoryPressureStatus(NSInteger level) {
    if (level == 0) return @"normal";
    if (level == 1 || level == 2) return @"erhöht";
    if (level >= 3) return @"kritisch";
    return @"nicht verfügbar";
}

static NSString *CBRootDiskName(NSString *deviceName) {
    NSString *name = deviceName.lastPathComponent ?: @"";
    NSRange sliceRange = [name rangeOfString:@"s[0-9]+$" options:NSRegularExpressionSearch];
    return sliceRange.location == NSNotFound ? name : [name substringToIndex:sliceRange.location];
}

static NSDictionary *CBTextAttributes(NSFont *preferredFont, CGFloat fallbackSize, NSFontWeight fallbackWeight, NSColor *preferredColor) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSFont *font = preferredFont ?: [NSFont systemFontOfSize:fallbackSize weight:fallbackWeight] ?: [NSFont systemFontOfSize:fallbackSize];
    NSColor *color = preferredColor ?: NSColor.labelColor ?: NSColor.blackColor;
    if (font != nil) attributes[NSFontAttributeName] = font;
    if (color != nil) attributes[NSForegroundColorAttributeName] = color;
    return attributes;
}

@interface CBLoginItemManager : NSObject
@property(class, nonatomic, readonly) NSString *plistPath;
@property(class, nonatomic, readonly, getter=isEnabled) BOOL enabled;
+ (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;
@end

@implementation CBLoginItemManager
+ (NSString *)plistPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/local.mpm.CoreBars.plist"];
}
+ (BOOL)isEnabled {
    return [NSFileManager.defaultManager fileExistsAtPath:self.plistPath];
}
+ (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    NSString *domain = [NSString stringWithFormat:@"gui/%u", getuid()];
    if (enabled) {
        NSDictionary *configuration = @{
            @"Label": @"local.mpm.CoreBars",
            @"ProgramArguments": @[@"/usr/bin/open", @"-g", NSBundle.mainBundle.bundlePath],
            @"RunAtLoad": @YES,
            @"LimitLoadToSessionType": @"Aqua"
        };
        if (![configuration writeToFile:self.plistPath atomically:YES]) {
            if (error) *error = [NSError errorWithDomain:@"CoreBars"
                                                    code:1
                                                userInfo:@{NSLocalizedDescriptionKey: @"LaunchAgent konnte nicht geschrieben werden."}];
            return NO;
        }
        [self runLaunchctl:@[@"bootstrap", domain, self.plistPath]];
        return YES;
    }

    [self runLaunchctl:@[@"bootout", [domain stringByAppendingString:@"/local.mpm.CoreBars"]]];
    return [NSFileManager.defaultManager removeItemAtPath:self.plistPath error:error];
}
+ (void)runLaunchctl:(NSArray<NSString *> *)arguments {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:nil];
    [task waitUntilExit];
}
@end

@interface CBTemperatureMonitor : NSObject
@property(atomic, readonly) double cpuTemperature;
@property(atomic, readonly) double gpuLoad;
@property(atomic, readonly) double pCpuFrequencyMHz;
@property(atomic, readonly) double eCpuFrequencyMHz;
@property(atomic, readonly) double pCpuMaxFrequencyMHz;
@property(atomic, readonly) double eCpuMaxFrequencyMHz;
@property(atomic, readonly) double cpuFrequencyPerformance;
@property(nonatomic, copy) dispatch_block_t updateHandler;
- (void)start;
- (void)stop;
@end

@implementation CBTemperatureMonitor {
    NSTask *_task;
    NSPipe *_outputPipe;
    NSMutableData *_buffer;
    double _cpuTemperature;
    double _gpuLoad;
    double _pCpuFrequencyMHz;
    double _eCpuFrequencyMHz;
    double _pCpuMaxFrequencyMHz;
    double _eCpuMaxFrequencyMHz;
    double _cpuFrequencyPerformance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cpuTemperature = NAN;
        _gpuLoad = NAN;
        _pCpuFrequencyMHz = NAN;
        _eCpuFrequencyMHz = NAN;
        _pCpuMaxFrequencyMHz = 3204;
        _eCpuMaxFrequencyMHz = 2064;
        _cpuFrequencyPerformance = NAN;
        _buffer = [NSMutableData data];
    }
    return self;
}

- (double)gpuLoad {
    @synchronized (self) {
        return _gpuLoad;
    }
}

- (double)cpuTemperature {
    @synchronized (self) {
        return _cpuTemperature;
    }
}

- (double)pCpuFrequencyMHz {
    @synchronized (self) {
        return _pCpuFrequencyMHz;
    }
}

- (double)eCpuFrequencyMHz {
    @synchronized (self) {
        return _eCpuFrequencyMHz;
    }
}

- (double)pCpuMaxFrequencyMHz {
    @synchronized (self) {
        return _pCpuMaxFrequencyMHz;
    }
}

- (double)eCpuMaxFrequencyMHz {
    @synchronized (self) {
        return _eCpuMaxFrequencyMHz;
    }
}

- (double)cpuFrequencyPerformance {
    @synchronized (self) {
        return _cpuFrequencyPerformance;
    }
}

- (void)start {
    if (_task.running) return;
    NSString *path = [NSBundle.mainBundle pathForResource:@"macmon" ofType:nil];
    if (path.length == 0) return;

    _task = [NSTask new];
    _task.executableURL = [NSURL fileURLWithPath:path];
    _task.arguments = @[@"pipe", @"-i", @"2000"];
    _outputPipe = [NSPipe pipe];
    _task.standardOutput = _outputPipe;
    _task.standardError = NSFileHandle.fileHandleWithNullDevice;

    __weak typeof(self) weakSelf = self;
    _outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            return;
        }
        [weakSelf consumeData:data];
    };

    NSError *error = nil;
    if (![_task launchAndReturnError:&error]) {
        _outputPipe.fileHandleForReading.readabilityHandler = nil;
        NSLog(@"CoreBars Temperatursensor konnte nicht starten: %@", error.localizedDescription);
    }
}

- (void)consumeData:(NSData *)data {
    @synchronized (_buffer) {
        [_buffer appendData:data];
        NSData *newline = [NSData dataWithBytes:"\n" length:1];
        while (YES) {
            NSRange range = [_buffer rangeOfData:newline options:0 range:NSMakeRange(0, _buffer.length)];
            if (range.location == NSNotFound) break;

            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, range.location)];
            [_buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(range)) withBytes:NULL length:0];
            if (line.length == 0) continue;

            id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if (![object isKindOfClass:NSDictionary.class]) continue;

            NSDictionary *json = object;
            NSDictionary *temperatures = [json[@"temp"] isKindOfClass:NSDictionary.class] ? json[@"temp"] : nil;
            NSNumber *temperature = [temperatures[@"cpu_temp_avg"] isKindOfClass:NSNumber.class]
                ? temperatures[@"cpu_temp_avg"] : nil;
            NSArray *gpuUsage = [json[@"gpu_usage"] isKindOfClass:NSArray.class] ? json[@"gpu_usage"] : nil;
            NSNumber *gpuLoad = gpuUsage.count > 1 && [gpuUsage[1] isKindOfClass:NSNumber.class]
                ? gpuUsage[1] : nil;
            double pFrequency = CBNormalizeFrequencyMHz(CBMaxNumberInObject(json[@"pcpu_freqs"] ?: json[@"pcpu_freq"]));
            double eFrequency = CBNormalizeFrequencyMHz(CBMaxNumberInObject(json[@"ecpu_freqs"] ?: json[@"ecpu_freq"]));
            BOOL hasFrequency = isfinite(pFrequency) || isfinite(eFrequency);
            BOOL hasUpdate = temperature.doubleValue > 0 || gpuLoad != nil || hasFrequency;
            if (hasUpdate) {
                @synchronized (self) {
                    if (temperature.doubleValue > 0) _cpuTemperature = temperature.doubleValue;
                    if (gpuLoad != nil) _gpuLoad = MIN(1, MAX(0, gpuLoad.doubleValue));
                    if (isfinite(pFrequency)) {
                        _pCpuFrequencyMHz = pFrequency;
                        _pCpuMaxFrequencyMHz = MAX(_pCpuMaxFrequencyMHz, pFrequency);
                    }
                    if (isfinite(eFrequency)) {
                        _eCpuFrequencyMHz = eFrequency;
                        _eCpuMaxFrequencyMHz = MAX(_eCpuMaxFrequencyMHz, eFrequency);
                    }
                    double pRatio = isfinite(_pCpuFrequencyMHz) && _pCpuMaxFrequencyMHz > 0
                        ? CBClamp(_pCpuFrequencyMHz / _pCpuMaxFrequencyMHz, 0, 1) : NAN;
                    double eRatio = isfinite(_eCpuFrequencyMHz) && _eCpuMaxFrequencyMHz > 0
                        ? CBClamp(_eCpuFrequencyMHz / _eCpuMaxFrequencyMHz, 0, 1) : NAN;
                    if (isfinite(pRatio) && isfinite(eRatio)) {
                        _cpuFrequencyPerformance = pRatio * 0.72 + eRatio * 0.28;
                    } else if (isfinite(pRatio)) {
                        _cpuFrequencyPerformance = pRatio;
                    } else if (isfinite(eRatio)) {
                        _cpuFrequencyPerformance = eRatio;
                    }
                }
                __weak typeof(self) weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    CBTemperatureMonitor *strongSelf = weakSelf;
                    if (strongSelf.updateHandler) strongSelf.updateHandler();
                });
            }
        }
    }
}

- (void)stop {
    _outputPipe.fileHandleForReading.readabilityHandler = nil;
    if (_task.running) [_task terminate];
}
@end

@interface CBMemoryConsumer : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint64_t bytes;
+ (instancetype)consumerWithName:(NSString *)name bytes:(uint64_t)bytes;
@end

@implementation CBMemoryConsumer
+ (instancetype)consumerWithName:(NSString *)name bytes:(uint64_t)bytes {
    CBMemoryConsumer *consumer = [CBMemoryConsumer new];
    consumer.name = name;
    consumer.bytes = bytes;
    return consumer;
}
@end

@interface CBCPUConsumer : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) double percent;
+ (instancetype)consumerWithName:(NSString *)name percent:(double)percent;
@end

@implementation CBCPUConsumer
+ (instancetype)consumerWithName:(NSString *)name percent:(double)percent {
    CBCPUConsumer *consumer = [CBCPUConsumer new];
    consumer.name = name;
    consumer.percent = percent;
    return consumer;
}
@end

@interface CBExternalDrive : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *mountPath;
@property(nonatomic, copy) NSString *deviceName;
@property(nonatomic, copy) NSString *rootDiskName;
@property(nonatomic) uint64_t totalBytes;
@property(nonatomic) uint64_t freeBytes;
@property(nonatomic) double readBytesPerSecond;
@property(nonatomic) double writeBytesPerSecond;
@property(nonatomic, readonly) double usedLoad;
@property(nonatomic, readonly) double activityBytesPerSecond;
+ (instancetype)driveWithName:(NSString *)name
                    mountPath:(NSString *)mountPath
                   deviceName:(NSString *)deviceName
                  rootDiskName:(NSString *)rootDiskName
                   totalBytes:(uint64_t)totalBytes
                    freeBytes:(uint64_t)freeBytes
            readBytesPerSecond:(double)readBytesPerSecond
           writeBytesPerSecond:(double)writeBytesPerSecond;
@end

@implementation CBExternalDrive
+ (instancetype)driveWithName:(NSString *)name
                    mountPath:(NSString *)mountPath
                   deviceName:(NSString *)deviceName
                  rootDiskName:(NSString *)rootDiskName
                   totalBytes:(uint64_t)totalBytes
                    freeBytes:(uint64_t)freeBytes
            readBytesPerSecond:(double)readBytesPerSecond
           writeBytesPerSecond:(double)writeBytesPerSecond {
    CBExternalDrive *drive = [CBExternalDrive new];
    drive.name = name;
    drive.mountPath = mountPath;
    drive.deviceName = deviceName;
    drive.rootDiskName = rootDiskName;
    drive.totalBytes = totalBytes;
    drive.freeBytes = freeBytes;
    drive.readBytesPerSecond = readBytesPerSecond;
    drive.writeBytesPerSecond = writeBytesPerSecond;
    return drive;
}
- (double)usedLoad {
    if (self.totalBytes == 0) return 0;
    return CBClamp((double)(self.totalBytes - MIN(self.freeBytes, self.totalBytes)) / self.totalBytes, 0, 1);
}
- (double)activityBytesPerSecond {
    return MAX(0, self.readBytesPerSecond) + MAX(0, self.writeBytesPerSecond);
}
@end

@interface CBSnapshot : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *coreLoads;
@property(nonatomic, copy) NSArray<NSString *> *coreTypes;
@property(nonatomic, copy) NSArray<CBMemoryConsumer *> *topMemoryConsumers;
@property(nonatomic, copy) NSArray<CBCPUConsumer *> *topCPUConsumers;
@property(nonatomic, copy) NSArray<CBExternalDrive *> *externalDrives;
@property(nonatomic) uint64_t memoryUsed;
@property(nonatomic) uint64_t memoryTotal;
@property(nonatomic) NSInteger memoryPressureLevel;
@property(nonatomic) uint64_t swapUsed;
@property(nonatomic) uint64_t swapTotal;
@property(nonatomic) double cpuTemperature;
@property(nonatomic) double gpuLoad;
@property(nonatomic) double pCpuFrequencyMHz;
@property(nonatomic) double eCpuFrequencyMHz;
@property(nonatomic) double pCpuMaxFrequencyMHz;
@property(nonatomic) double eCpuMaxFrequencyMHz;
@property(nonatomic) double cpuFrequencyPerformance;
@property(nonatomic) NSProcessInfoThermalState thermalState;
@property(nonatomic) BOOL externalPowerConnected;
@property(nonatomic) BOOL batteryCharging;
@property(nonatomic) double chargingWatts;
@property(nonatomic) double batteryDrainWatts;
@property(nonatomic) uint64_t internalDiskFreeBytes;
@property(nonatomic) uint64_t internalDiskTotalBytes;
@property(nonatomic, copy) NSString *sustainedCPUProcess;
@property(nonatomic) double sustainedCPUPercent;
@property(nonatomic) NSTimeInterval sustainedCPUSeconds;
@property(nonatomic, readonly) double totalCPULoad;
@property(nonatomic, readonly) double superCPULoad;
@property(nonatomic, readonly) double performanceCPULoad;
@property(nonatomic, readonly) double efficiencyCPULoad;
@property(nonatomic, readonly) double memoryLoad;
@property(nonatomic, readonly) double swapLoad;
@property(nonatomic, readonly) double thermalPerformance;
@property(nonatomic, readonly) double effectivePerformance;
- (double)averageLoadForType:(NSString *)type;
@end

@implementation CBSnapshot
- (double)totalCPULoad {
    if (self.coreLoads.count == 0) return 0;
    double total = 0;
    for (NSNumber *load in self.coreLoads) total += load.doubleValue;
    return total / self.coreLoads.count;
}
- (double)performanceCPULoad {
    return [self averageLoadForType:@"P"];
}
- (double)superCPULoad {
    return [self averageLoadForType:@"S"];
}
- (double)efficiencyCPULoad {
    return [self averageLoadForType:@"E"];
}
- (double)averageLoadForType:(NSString *)type {
    double total = 0;
    NSUInteger count = 0;
    NSUInteger limit = MIN(self.coreLoads.count, self.coreTypes.count);
    for (NSUInteger index = 0; index < limit; index++) {
        if ([self.coreTypes[index] isEqualToString:type]) {
            total += self.coreLoads[index].doubleValue;
            count++;
        }
    }
    return count == 0 ? 0 : total / count;
}
- (double)memoryLoad {
    return self.memoryTotal == 0 ? 0 : MIN(1, (double)self.memoryUsed / self.memoryTotal);
}
- (double)swapLoad {
    return self.swapTotal == 0 ? 0 : MIN(1, (double)self.swapUsed / self.swapTotal);
}
- (double)thermalPerformance {
    double stateLimit = 1.0;
    switch (self.thermalState) {
        case NSProcessInfoThermalStateNominal: stateLimit = 1.0; break;
        case NSProcessInfoThermalStateFair: stateLimit = 0.88; break;
        case NSProcessInfoThermalStateSerious: stateLimit = 0.68; break;
        case NSProcessInfoThermalStateCritical: stateLimit = 0.48; break;
    }

    if (!isfinite(self.cpuTemperature)) return stateLimit;
    double temperatureLimit = 1.0;
    if (self.cpuTemperature >= 95) {
        temperatureLimit = 0.55;
    } else if (self.cpuTemperature >= 85) {
        temperatureLimit = 1.0 - ((self.cpuTemperature - 85) / 10.0) * 0.45;
    }
    return CBClamp(MIN(stateLimit, temperatureLimit), 0.35, 1.0);
}
- (double)effectivePerformance {
    double thermal = self.thermalPerformance;
    if (isfinite(self.cpuFrequencyPerformance)) {
        double frequency = CBClamp(self.cpuFrequencyPerformance, 0.05, 1.0);
        if (self.totalCPULoad >= 0.35) return MIN(frequency, thermal);
        return MIN(MAX(frequency, thermal), 1.0);
    }
    return thermal;
}
@end

@interface CBSystemMonitor : NSObject
@property(nonatomic, readonly) CBSnapshot *latestSnapshot;
- (CBSnapshot *)sample;
@end

@implementation CBSystemMonitor {
    NSArray<NSArray<NSNumber *> *> *_previousTicks;
    NSArray<NSString *> *_coreTypes;
    NSArray<CBMemoryConsumer *> *_topMemoryConsumers;
    NSArray<CBCPUConsumer *> *_topCPUConsumers;
    NSDictionary<NSNumber *, NSNumber *> *_previousProcessCPUTicks;
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *_previousExternalDiskBytes;
    NSTimeInterval _lastProcessMemorySample;
    NSTimeInterval _lastExternalDriveSample;
    NSString *_highCPUProcess;
    NSTimeInterval _highCPUStart;
    double _previousBatteryCapacityMah;
    NSTimeInterval _previousBatteryCapacitySample;
    CBSnapshot *_latestSnapshot;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _latestSnapshot = [CBSnapshot new];
        NSUInteger count = MAX(1, NSProcessInfo.processInfo.processorCount);
        _coreTypes = [self readCoreTypesForCount:count];
        _latestSnapshot.coreLoads = [self zeroLoads:_coreTypes.count];
        _latestSnapshot.coreTypes = _coreTypes;
        _latestSnapshot.topMemoryConsumers = @[];
        _latestSnapshot.topCPUConsumers = @[];
        _latestSnapshot.externalDrives = @[];
        _latestSnapshot.memoryTotal = NSProcessInfo.processInfo.physicalMemory;
        _latestSnapshot.memoryPressureLevel = -1;
        _latestSnapshot.swapUsed = 0;
        _latestSnapshot.swapTotal = 0;
        _latestSnapshot.cpuTemperature = NAN;
        _latestSnapshot.gpuLoad = NAN;
        _latestSnapshot.pCpuFrequencyMHz = NAN;
        _latestSnapshot.eCpuFrequencyMHz = NAN;
        _latestSnapshot.pCpuMaxFrequencyMHz = NAN;
        _latestSnapshot.eCpuMaxFrequencyMHz = NAN;
        _latestSnapshot.cpuFrequencyPerformance = NAN;
        _latestSnapshot.thermalState = NSProcessInfo.processInfo.thermalState;
        _latestSnapshot.externalPowerConnected = NO;
        _latestSnapshot.batteryCharging = NO;
        _latestSnapshot.chargingWatts = NAN;
        _latestSnapshot.batteryDrainWatts = NAN;
        _latestSnapshot.internalDiskFreeBytes = 0;
        _latestSnapshot.internalDiskTotalBytes = 0;
        _previousExternalDiskBytes = [NSMutableDictionary dictionary];
        _previousBatteryCapacityMah = 0;
        _previousBatteryCapacitySample = 0;
    }
    return self;
}

- (CBSnapshot *)latestSnapshot { return _latestSnapshot; }

- (NSArray<NSNumber *> *)zeroLoads:(NSUInteger)count {
    NSMutableArray *loads = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [loads addObject:@0.0];
    return loads;
}

- (CBSnapshot *)sample {
    CBSnapshot *snapshot = [CBSnapshot new];
    snapshot.coreLoads = [self readCoreLoads];
    snapshot.coreTypes = _coreTypes;
    snapshot.memoryTotal = NSProcessInfo.processInfo.physicalMemory;
    snapshot.memoryUsed = [self readMemoryUsedWithTotal:snapshot.memoryTotal];
    snapshot.memoryPressureLevel = [self readMemoryPressureLevel];
    [self readSwapUsageIntoSnapshot:snapshot];
    [self readInternalDiskIntoSnapshot:snapshot];
    snapshot.topMemoryConsumers = [self readTopMemoryConsumersIfNeeded];
    snapshot.topCPUConsumers = _topCPUConsumers ?: @[];
    [self updateSustainedCPUIntoSnapshot:snapshot];
    snapshot.externalDrives = [self readExternalDrives];
    snapshot.thermalState = NSProcessInfo.processInfo.thermalState;
    [self readBatteryPowerIntoSnapshot:snapshot];
    _latestSnapshot = snapshot;
    return snapshot;
}

- (NSInteger)readMemoryPressureLevel {
    // XNU reports 0 normal, 1 warning, 2 urgent, 3 critical, and 4 jetsam.
    int level = -1;
    size_t size = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0) != 0 || size != sizeof(level)) {
        return -1;
    }
    return level >= 0 && level <= 4 ? level : -1;
}

- (void)updateSustainedCPUIntoSnapshot:(CBSnapshot *)snapshot {
    CBCPUConsumer *leader = snapshot.topCPUConsumers.firstObject;
    if (leader == nil || leader.percent < 80.0) {
        _highCPUProcess = nil;
        _highCPUStart = 0;
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (![_highCPUProcess isEqualToString:leader.name]) {
        _highCPUProcess = leader.name.copy;
        _highCPUStart = now;
    }
    if (now - _highCPUStart >= 30.0) {
        snapshot.sustainedCPUProcess = _highCPUProcess;
        snapshot.sustainedCPUPercent = leader.percent;
        snapshot.sustainedCPUSeconds = now - _highCPUStart;
    }
}

- (void)readBatteryPowerIntoSnapshot:(CBSnapshot *)snapshot {
    snapshot.externalPowerConnected = NO;
    snapshot.batteryCharging = NO;
    snapshot.chargingWatts = NAN;
    snapshot.batteryDrainWatts = NAN;

    io_service_t battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (battery == MACH_PORT_NULL) return;

    CFMutableDictionaryRef propertiesRef = NULL;
    kern_return_t result = IORegistryEntryCreateCFProperties(battery, &propertiesRef, kCFAllocatorDefault, 0);
    IOObjectRelease(battery);
    if (result != KERN_SUCCESS || propertiesRef == NULL) return;

    NSDictionary *properties = CFBridgingRelease(propertiesRef);
    BOOL externalConnected = [properties[@"ExternalConnected"] boolValue] || [properties[@"AppleRawExternalConnected"] boolValue];
    BOOL isCharging = [properties[@"IsCharging"] boolValue];
    int64_t amperage = CBSignedBatteryInteger(properties[@"Amperage"]);
    int64_t instantAmperage = CBSignedBatteryInteger(properties[@"InstantAmperage"]);
    int64_t voltage = CBSignedBatteryInteger(properties[@"Voltage"]);
    if (voltage <= 0) voltage = CBSignedBatteryInteger(properties[@"AppleRawBatteryVoltage"]);
    int64_t rawCapacity = CBSignedBatteryInteger(properties[@"AppleRawCurrentCapacity"]);

    NSDictionary *chargerData = [properties[@"ChargerData"] isKindOfClass:NSDictionary.class] ? properties[@"ChargerData"] : nil;
    int64_t chargingCurrent = CBSignedBatteryInteger(chargerData[@"ChargingCurrent"]);
    int64_t chargingVoltage = CBSignedBatteryInteger(chargerData[@"ChargingVoltage"]);
    NSDictionary *adapterDetails = [properties[@"AdapterDetails"] isKindOfClass:NSDictionary.class] ? properties[@"AdapterDetails"] : nil;
    NSArray *rawAdapterDetails = [properties[@"AppleRawAdapterDetails"] isKindOfClass:NSArray.class] ? properties[@"AppleRawAdapterDetails"] : nil;
    NSDictionary *rawAdapter = [rawAdapterDetails.firstObject isKindOfClass:NSDictionary.class] ? rawAdapterDetails.firstObject : nil;

    double adapterWatts = CBMaxNumberInObject(adapterDetails[@"Watts"]);
    if (!isfinite(adapterWatts) || adapterWatts <= 0) adapterWatts = CBMaxNumberInObject(rawAdapter[@"Watts"]);

    double chargingWatts = (isCharging && chargingCurrent > 0 && chargingVoltage > 0)
        ? ((double)chargingCurrent * (double)chargingVoltage / 1000000.0)
        : NAN;
    double watts = (isfinite(adapterWatts) && adapterWatts > 0) ? adapterWatts : chargingWatts;

    snapshot.externalPowerConnected = externalConnected;
    snapshot.batteryCharging = externalConnected && isfinite(watts) && watts > 0.5;
    snapshot.chargingWatts = snapshot.batteryCharging ? watts : NAN;

    int64_t dischargeCurrent = amperage < 0 ? amperage : instantAmperage;
    if (!externalConnected && dischargeCurrent < 0 && voltage > 0) {
        snapshot.batteryDrainWatts = ((double)(-dischargeCurrent) * (double)voltage / 1000000.0);
    } else if (!externalConnected) {
        snapshot.batteryDrainWatts = 0;
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (rawCapacity > 0 && voltage > 0) {
            if (_previousBatteryCapacityMah > 0 && rawCapacity < _previousBatteryCapacityMah && _previousBatteryCapacitySample > 0) {
                double interval = MAX(1.0, now - _previousBatteryCapacitySample);
                double capacityDeltaMah = _previousBatteryCapacityMah - (double)rawCapacity;
                snapshot.batteryDrainWatts = capacityDeltaMah * 3600.0 / interval * (double)voltage / 1000000.0;
                _previousBatteryCapacityMah = (double)rawCapacity;
                _previousBatteryCapacitySample = now;
            } else if (_previousBatteryCapacityMah <= 0 || rawCapacity > _previousBatteryCapacityMah) {
                _previousBatteryCapacityMah = (double)rawCapacity;
                _previousBatteryCapacitySample = now;
            }
        }
    } else {
        _previousBatteryCapacityMah = rawCapacity > 0 ? (double)rawCapacity : 0;
        _previousBatteryCapacitySample = rawCapacity > 0 ? NSDate.date.timeIntervalSinceReferenceDate : 0;
    }
}

- (NSArray<CBExternalDrive *> *)readExternalDrives {
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    if (count <= 0) return @[];

    NSMutableData *mountData = [NSMutableData dataWithLength:(NSUInteger)count * sizeof(struct statfs)];
    struct statfs *mounts = mountData.mutableBytes;
    int usedCount = getfsstat(mounts, (int)mountData.length, MNT_NOWAIT);
    if (usedCount <= 0) return @[];

    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    double interval = _lastExternalDriveSample > 0 ? MAX(0.2, now - _lastExternalDriveSample) : 0;
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *nextDiskBytes = [NSMutableDictionary dictionary];
    NSMutableArray<CBExternalDrive *> *drives = [NSMutableArray array];

    for (int index = 0; index < usedCount; index++) {
        struct statfs mount = mounts[index];
        NSString *mountPath = [NSString stringWithUTF8String:mount.f_mntonname] ?: @"";
        NSString *deviceName = [NSString stringWithUTF8String:mount.f_mntfromname] ?: @"";
        if (![mountPath hasPrefix:@"/Volumes/"] || ![deviceName hasPrefix:@"/dev/"]) continue;

        NSString *name = mountPath.lastPathComponent.length > 0 ? mountPath.lastPathComponent : deviceName.lastPathComponent;
        NSString *rootDiskName = CBRootDiskName(deviceName);
        uint64_t blockSize = (uint64_t)MAX(1, mount.f_bsize);
        uint64_t total = (uint64_t)mount.f_blocks * blockSize;
        uint64_t free = (uint64_t)mount.f_bavail * blockSize;
        if (total == 0) continue;

        NSDictionary<NSString *, NSNumber *> *counters = [self diskByteCountersForBSDName:rootDiskName];
        NSDictionary<NSString *, NSNumber *> *previousCounters = _previousExternalDiskBytes[rootDiskName];
        uint64_t readBytes = counters[@"read"].unsignedLongLongValue;
        uint64_t writeBytes = counters[@"write"].unsignedLongLongValue;
        double readRate = 0;
        double writeRate = 0;
        if (previousCounters != nil && interval > 0) {
            uint64_t previousRead = previousCounters[@"read"].unsignedLongLongValue;
            uint64_t previousWrite = previousCounters[@"write"].unsignedLongLongValue;
            readRate = readBytes >= previousRead ? (double)(readBytes - previousRead) / interval : 0;
            writeRate = writeBytes >= previousWrite ? (double)(writeBytes - previousWrite) / interval : 0;
        }

        if (counters != nil) {
            nextDiskBytes[rootDiskName] = counters;
        }
        [drives addObject:[CBExternalDrive driveWithName:name
                                               mountPath:mountPath
                                              deviceName:deviceName
                                             rootDiskName:rootDiskName
                                              totalBytes:total
                                               freeBytes:free
                                      readBytesPerSecond:readRate
                                     writeBytesPerSecond:writeRate]];
    }

    [drives sortUsingComparator:^NSComparisonResult(CBExternalDrive *first, CBExternalDrive *second) {
        return [first.name compare:second.name options:NSCaseInsensitiveSearch];
    }];
    _previousExternalDiskBytes = nextDiskBytes;
    _lastExternalDriveSample = now;
    return drives;
}

- (NSDictionary<NSString *, NSNumber *> *)diskByteCountersForBSDName:(NSString *)bsdName {
    if (bsdName.length == 0) return nil;

    io_iterator_t iterator = MACH_PORT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator);
    if (result != KERN_SUCCESS || iterator == MACH_PORT_NULL) return nil;

    NSDictionary<NSString *, NSNumber *> *counters = nil;
    io_object_t media = MACH_PORT_NULL;
    while ((media = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        CFTypeRef bsdNameRef = IORegistryEntryCreateCFProperty(media, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        NSString *candidate = CFBridgingRelease(bsdNameRef);
        if ([candidate isEqualToString:bsdName]) {
            io_registry_entry_t parent = MACH_PORT_NULL;
            if (IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) == KERN_SUCCESS) {
                CFTypeRef statisticsRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Statistics"), kCFAllocatorDefault, 0);
                NSDictionary *statistics = CFBridgingRelease(statisticsRef);
                NSNumber *read = [statistics[@"Bytes (Read)"] isKindOfClass:NSNumber.class] ? statistics[@"Bytes (Read)"] : @0;
                NSNumber *write = [statistics[@"Bytes (Write)"] isKindOfClass:NSNumber.class] ? statistics[@"Bytes (Write)"] : @0;
                counters = @{@"read": read, @"write": write};
                IOObjectRelease(parent);
            }
            IOObjectRelease(media);
            break;
        }
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);
    return counters;
}

- (NSArray<NSString *> *)readCoreTypesForCount:(NSUInteger)count {
    int efficiencyCount = 0;
    size_t size = sizeof(efficiencyCount);
    if (sysctlbyname("hw.perflevel1.logicalcpu", &efficiencyCount, &size, NULL, 0) != 0) {
        efficiencyCount = 0;
    }

    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [types addObject:index < (NSUInteger)MAX(0, efficiencyCount) ? @"E" : @"P"];
    }
    return types;
}

- (NSArray<NSNumber *> *)readCoreLoads {
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    natural_t processorCount = 0;
    kern_return_t result = host_processor_info(
        mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount
    );
    if (result != KERN_SUCCESS || info == NULL) return _latestSnapshot.coreLoads;

    NSMutableArray<NSArray<NSNumber *> *> *current = [NSMutableArray arrayWithCapacity:processorCount];
    for (NSUInteger core = 0; core < processorCount; core++) {
        NSUInteger offset = core * CPU_STATE_MAX;
        [current addObject:@[
            @((uint64_t)info[offset + CPU_STATE_USER]),
            @((uint64_t)info[offset + CPU_STATE_SYSTEM]),
            @((uint64_t)info[offset + CPU_STATE_NICE]),
            @((uint64_t)info[offset + CPU_STATE_IDLE])
        ]];
    }

    vm_size_t bytes = (vm_size_t)infoCount * sizeof(integer_t);
    vm_deallocate(mach_task_self(), (vm_address_t)info, bytes);

    NSArray<NSNumber *> *loads;
    if (_previousTicks.count != current.count) {
        loads = [self zeroLoads:current.count];
    } else {
        NSMutableArray *calculated = [NSMutableArray arrayWithCapacity:current.count];
        for (NSUInteger core = 0; core < current.count; core++) {
            NSArray<NSNumber *> *now = current[core];
            NSArray<NSNumber *> *old = _previousTicks[core];
            uint64_t delta[4];
            for (NSUInteger state = 0; state < 4; state++) {
                uint64_t n = now[state].unsignedLongLongValue;
                uint64_t o = old[state].unsignedLongLongValue;
                delta[state] = n >= o ? n - o : 0;
            }
            uint64_t active = delta[0] + delta[1] + delta[2];
            uint64_t total = active + delta[3];
            [calculated addObject:@(total == 0 ? 0 : MIN(1, (double)active / total))];
        }
        loads = calculated;
    }
    _previousTicks = current;
    return loads;
}

- (uint64_t)readMemoryUsedWithTotal:(uint64_t)total {
    vm_statistics64_data_t stats = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(
        mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count
    );
    if (result != KERN_SUCCESS) return _latestSnapshot.memoryUsed;
    uint64_t pages = stats.active_count + stats.wire_count + stats.compressor_page_count;
    return MIN(total, pages * (uint64_t)vm_kernel_page_size);
}

- (void)readSwapUsageIntoSnapshot:(CBSnapshot *)snapshot {
    struct xsw_usage usage = {0};
    size_t size = sizeof(usage);
    if (sysctlbyname("vm.swapusage", &usage, &size, NULL, 0) != 0) {
        snapshot.swapUsed = _latestSnapshot.swapUsed;
        snapshot.swapTotal = _latestSnapshot.swapTotal;
        return;
    }

    snapshot.swapUsed = usage.xsu_used;
    snapshot.swapTotal = usage.xsu_total;
}

- (void)readInternalDiskIntoSnapshot:(CBSnapshot *)snapshot {
    struct statfs root = {0};
    if (statfs("/", &root) != 0) {
        snapshot.internalDiskFreeBytes = _latestSnapshot.internalDiskFreeBytes;
        snapshot.internalDiskTotalBytes = _latestSnapshot.internalDiskTotalBytes;
        return;
    }

    uint64_t blockSize = (uint64_t)MAX(1, root.f_bsize);
    snapshot.internalDiskFreeBytes = (uint64_t)root.f_bavail * blockSize;
    snapshot.internalDiskTotalBytes = (uint64_t)root.f_blocks * blockSize;
}

- (NSArray<CBMemoryConsumer *> *)readTopMemoryConsumersIfNeeded {
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (_topMemoryConsumers != nil && now - _lastProcessMemorySample < 3.0) {
        return _topMemoryConsumers;
    }

    int byteCount = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return _topMemoryConsumers ?: @[];

    NSMutableData *pidData = [NSMutableData dataWithLength:(NSUInteger)byteCount];
    int usedBytes = proc_listpids(PROC_ALL_PIDS, 0, pidData.mutableBytes, byteCount);
    if (usedBytes <= 0) return _topMemoryConsumers ?: @[];

    pid_t *pids = pidData.mutableBytes;
    int pidCount = usedBytes / (int)sizeof(pid_t);
    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *cpuTotals = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *currentCPUTicks = [NSMutableDictionary dictionary];
    double interval = _lastProcessMemorySample > 0 ? now - _lastProcessMemorySample : 0;
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);

    for (int index = 0; index < pidCount; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;

        struct proc_taskinfo taskInfo = {0};
        int infoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, sizeof(taskInfo));
        if (infoSize != sizeof(taskInfo)) continue;

        char nameBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int nameLength = proc_name(pid, nameBuffer, sizeof(nameBuffer));
        if (nameLength <= 0) continue;

        NSString *name = [NSString stringWithUTF8String:nameBuffer];
        if (name.length == 0) continue;

        if (taskInfo.pti_resident_size > 0) {
            uint64_t previous = totals[name].unsignedLongLongValue;
            totals[name] = @(previous + (uint64_t)taskInfo.pti_resident_size);
        }

        uint64_t ticks = taskInfo.pti_total_user + taskInfo.pti_total_system;
        NSNumber *pidKey = @(pid);
        currentCPUTicks[pidKey] = @(ticks);
        NSNumber *previousTicks = _previousProcessCPUTicks[pidKey];
        if (previousTicks == nil || ticks < previousTicks.unsignedLongLongValue || interval <= 0 || timebase.denom == 0) continue;
        double elapsedCPUSeconds = (double)(ticks - previousTicks.unsignedLongLongValue)
            * (double)timebase.numer / (double)timebase.denom / 1000000000.0;
        double percent = elapsedCPUSeconds / interval * 100.0;
        if (!isfinite(percent) || percent <= 0) continue;
        cpuTotals[name] = @(cpuTotals[name].doubleValue + percent);
    }

    NSMutableArray<CBMemoryConsumer *> *consumers = [NSMutableArray arrayWithCapacity:totals.count];
    [totals enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *bytes, BOOL *stop) {
        [consumers addObject:[CBMemoryConsumer consumerWithName:name bytes:bytes.unsignedLongLongValue]];
    }];
    [consumers sortUsingComparator:^NSComparisonResult(CBMemoryConsumer *first, CBMemoryConsumer *second) {
        if (first.bytes == second.bytes) return [first.name compare:second.name options:NSCaseInsensitiveSearch];
        return first.bytes > second.bytes ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSUInteger limit = MIN((NSUInteger)8, consumers.count);
    _topMemoryConsumers = limit > 0 ? [consumers subarrayWithRange:NSMakeRange(0, limit)] : @[];
    NSMutableArray<CBCPUConsumer *> *cpuConsumers = [NSMutableArray arrayWithCapacity:cpuTotals.count];
    [cpuTotals enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *percent, BOOL *stop) {
        [cpuConsumers addObject:[CBCPUConsumer consumerWithName:name percent:percent.doubleValue]];
    }];
    [cpuConsumers sortUsingComparator:^NSComparisonResult(CBCPUConsumer *first, CBCPUConsumer *second) {
        if (first.percent == second.percent) return [first.name compare:second.name options:NSCaseInsensitiveSearch];
        return first.percent > second.percent ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger cpuLimit = MIN((NSUInteger)6, cpuConsumers.count);
    _topCPUConsumers = cpuLimit > 0 ? [cpuConsumers subarrayWithRange:NSMakeRange(0, cpuLimit)] : @[];
    _previousProcessCPUTicks = currentCPUTicks;
    _lastProcessMemorySample = now;
    return _topMemoryConsumers;
}
@end

@interface CBStatusBarsView : NSView
@property(nonatomic) CBSnapshot *snapshot;
@property(nonatomic, copy) dispatch_block_t clickHandler;
@property(nonatomic, readonly) CGFloat preferredWidth;
@end

@implementation CBStatusBarsView
- (BOOL)isFlipped { return NO; }
- (CGFloat)preferredWidth {
    CGFloat cores = self.snapshot.coreLoads.count;
    NSUInteger groups = [self orderedCoreTypesForSnapshot:self.snapshot].count;
    CGFloat chargingWidth = isfinite(self.snapshot.chargingWatts) ? 34 : 0;
    CGFloat externalWidth = self.snapshot.externalDrives.count > 0 ? 74 : 0;
    return 8 + externalWidth + 13 + cores * 3 + MAX(0, cores - 1) + groups * 10 + 4 + 4 + 32 + 34 + chargingWidth;
}
- (void)setSnapshot:(CBSnapshot *)snapshot {
    _snapshot = snapshot;
    NSString *used = [NSByteCountFormatter stringFromByteCount:snapshot.memoryUsed countStyle:NSByteCountFormatterCountStyleMemory];
    NSString *total = [NSByteCountFormatter stringFromByteCount:snapshot.memoryTotal countStyle:NSByteCountFormatterCountStyleMemory];
    NSString *temperature = isfinite(snapshot.cpuTemperature)
        ? [NSString stringWithFormat:@"%.0f °C", snapshot.cpuTemperature] : @"– °C";
    NSString *gpu = isfinite(snapshot.gpuLoad)
        ? [NSString stringWithFormat:@"%.0f%%", snapshot.gpuLoad * 100] : @"–";
    NSString *performance = [NSString stringWithFormat:@"%.0f%%", snapshot.effectivePerformance * 100];
    NSString *swap = snapshot.swapTotal > 0
        ? [NSString stringWithFormat:@" · SWAP: %@", CBShortByteText(snapshot.swapUsed)]
        : @"";
    NSString *clock = isfinite(snapshot.pCpuFrequencyMHz)
        ? [NSString stringWithFormat:@" · P %.0f/%.0f MHz", snapshot.pCpuFrequencyMHz, snapshot.pCpuMaxFrequencyMHz]
        : @"";
    NSString *charging = isfinite(snapshot.chargingWatts)
        ? [NSString stringWithFormat:@" · Netzteil: %.0f W", snapshot.chargingWatts]
        : (snapshot.externalPowerConnected ? @" · Netzteil: verbunden" : @"");
    NSMutableArray<NSString *> *driveParts = [NSMutableArray array];
    for (CBExternalDrive *drive in snapshot.externalDrives) {
        [driveParts addObject:[NSString stringWithFormat:@"%@: %@ frei · R %@ · W %@ · %@",
                               drive.name,
                               CBShortByteText(drive.freeBytes),
                               CBRateText(drive.readBytesPerSecond),
                               CBRateText(drive.writeBytesPerSecond),
                               CBMbitRateText(drive.activityBytesPerSecond)]];
    }
    NSString *drives = driveParts.count > 0
        ? [NSString stringWithFormat:@" · Extern: %@", [driveParts componentsJoinedByString:@" · "]]
        : @"";
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSString *type in [self orderedCoreTypesForSnapshot:snapshot]) {
        [groups addObject:[NSString stringWithFormat:@"%@: %.0f%%", type, [snapshot averageLoadForType:type] * 100]];
    }
    self.toolTip = [NSString stringWithFormat:@"Leistung: %@%@%@%@%@ · Thermal: %@ · GPU: %@ · CPU: %.0f%% · %@ · %@ · RAM: %@ / %@",
                    performance, clock, charging, swap, drives, CBThermalStateName(snapshot.thermalState),
                    gpu, snapshot.totalCPULoad * 100, [groups componentsJoinedByString:@" · "],
                    temperature, used, total];
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event {
    if (self.clickHandler) self.clickHandler();
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat height = MAX(8, NSHeight(self.bounds) - 7);
    CGFloat x = 4;
    NSString *previousType = nil;
    NSDictionary *typeAttributes = CBTextAttributes(
        [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold],
        9,
        NSFontWeightBold,
        NSColor.secondaryLabelColor
    );
    CBExternalDrive *externalDrive = self.snapshot.externalDrives.firstObject;
    if (externalDrive != nil) {
        NSString *free = CBShortByteText(externalDrive.freeBytes);
        NSDictionary *driveAttributes = CBTextAttributes(
            [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
            10,
            NSFontWeightSemibold,
            NSColor.systemBlueColor
        );
        NSSize freeSize = [free sizeWithAttributes:driveAttributes];
        [free drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - freeSize.height) / 2))
          withAttributes:driveAttributes];
        x += freeSize.width + 3;
        [self drawBarAtX:x width:4 height:height load:externalDrive.usedLoad color:NSColor.systemBlueColor];
        x += 7;
        NSString *rate = CBCompactMbitRateText(externalDrive.activityBytesPerSecond);
        NSDictionary *rateAttributes = CBTextAttributes(
            [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightSemibold],
            9,
            NSFontWeightSemibold,
            NSColor.systemBlueColor
        );
        NSSize rateSize = [rate sizeWithAttributes:rateAttributes];
        [rate drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - rateSize.height) / 2))
           withAttributes:rateAttributes];
        x += rateSize.width + 6;
    }

    NSString *performance = [NSString stringWithFormat:@"%.0f%%", self.snapshot.effectivePerformance * 100];
    double effective = self.snapshot.effectivePerformance;
    NSColor *performanceColor = effective > .85 ? NSColor.systemGreenColor :
        effective > .65 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
    NSDictionary *performanceAttributes = CBTextAttributes(
        [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
        10,
        NSFontWeightSemibold,
        performanceColor
    );
    NSSize performanceSize = [performance sizeWithAttributes:performanceAttributes];
    [performance drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - performanceSize.height) / 2))
              withAttributes:performanceAttributes];
    x += performanceSize.width + 6;

    if (isfinite(self.snapshot.chargingWatts)) {
        NSString *watts = [NSString stringWithFormat:@"%.0fW", self.snapshot.chargingWatts];
        NSColor *wattsColor = self.snapshot.chargingWatts >= 25 ? NSColor.systemGreenColor : NSColor.systemYellowColor;
        NSDictionary *wattsAttributes = CBTextAttributes(
            [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
            10,
            NSFontWeightSemibold,
            wattsColor
        );
        NSSize wattsSize = [watts sizeWithAttributes:wattsAttributes];
        [watts drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - wattsSize.height) / 2))
            withAttributes:wattsAttributes];
        x += wattsSize.width + 6;
    }

    NSSize gpuTypeSize = [@"G" sizeWithAttributes:typeAttributes];
    [@"G" drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - gpuTypeSize.height) / 2))
       withAttributes:typeAttributes];
    x += 9;
    [self drawBarAtX:x
               width:4
              height:height
                load:isfinite(self.snapshot.gpuLoad) ? self.snapshot.gpuLoad : 0
               color:NSColor.systemPurpleColor];
    x += 8;

    NSMutableArray<NSNumber *> *displayOrder = [NSMutableArray array];
    for (NSString *type in [self orderedCoreTypesForSnapshot:self.snapshot]) {
        for (NSUInteger index = 0; index < self.snapshot.coreLoads.count; index++) {
            NSString *coreType = index < self.snapshot.coreTypes.count ? self.snapshot.coreTypes[index] : @"?";
            if ([coreType isEqualToString:type]) [displayOrder addObject:@(index)];
        }
    }
    for (NSNumber *indexNumber in displayOrder) {
        NSUInteger index = indexNumber.unsignedIntegerValue;
        NSNumber *number = self.snapshot.coreLoads[index];
        NSString *type = index < self.snapshot.coreTypes.count ? self.snapshot.coreTypes[index] : @"?";
        if (![type isEqualToString:previousType]) {
            if (previousType != nil) x += 3;
            NSSize typeSize = [type sizeWithAttributes:typeAttributes];
            [type drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - typeSize.height) / 2))
              withAttributes:typeAttributes];
            x += 9;
            previousType = type;
        }
        double load = number.doubleValue;
        NSColor *color = load < .55 ? NSColor.systemGreenColor :
                         load < .82 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
        [self drawBarAtX:x width:3 height:height load:load color:color];
        x += 4;
    }
    x += 3;
    [self drawBarAtX:x width:4 height:height load:self.snapshot.memoryLoad color:NSColor.systemBlueColor];
    x += 8;
    NSString *temperature = isfinite(self.snapshot.cpuTemperature)
        ? [NSString stringWithFormat:@"%.0f°", self.snapshot.cpuTemperature] : @"--°";
    NSColor *temperatureColor = !isfinite(self.snapshot.cpuTemperature) ? NSColor.secondaryLabelColor :
        self.snapshot.cpuTemperature < 70 ? NSColor.systemGreenColor :
        self.snapshot.cpuTemperature < 85 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
    NSDictionary *attributes = CBTextAttributes(
        [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],
        10,
        NSFontWeightMedium,
        temperatureColor
    );
    NSSize textSize = [temperature sizeWithAttributes:attributes];
    [temperature drawAtPoint:NSMakePoint(x, floor((NSHeight(self.bounds) - textSize.height) / 2))
              withAttributes:attributes];
}
- (void)drawBarAtX:(CGFloat)x width:(CGFloat)width height:(CGFloat)height load:(double)load color:(NSColor *)color {
    NSRect background = NSMakeRect(x, 3, width, height);
    [[NSColor.labelColor colorWithAlphaComponent:.14] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:background xRadius:1 yRadius:1] fill];
    CGFloat filled = load > 0 ? MAX(1, height * load) : 0;
    [(color ?: NSColor.labelColor ?: NSColor.blackColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, 3, width, filled) xRadius:1 yRadius:1] fill];
}
- (NSArray<NSString *> *)orderedCoreTypesForSnapshot:(CBSnapshot *)snapshot {
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *candidate in @[@"S", @"P", @"E"]) {
        if ([snapshot.coreTypes containsObject:candidate]) [ordered addObject:candidate];
    }
    for (NSString *type in snapshot.coreTypes) {
        if (![ordered containsObject:type]) [ordered addObject:type];
    }
    return ordered;
}
@end

@interface CBPopoverController : NSViewController
- (void)updateWithSnapshot:(CBSnapshot *)snapshot;
@end

@implementation CBPopoverController {
    NSTextField *_gpuLabel;
    NSTextField *_cpuLabel;
    NSTextField *_superLabel;
    NSTextField *_performanceLabel;
    NSTextField *_efficiencyLabel;
    NSTextField *_coreLegendLabel;
    NSTextField *_externalDriveLabel;
    NSTextField *_performanceHeadroomLabel;
    NSTextField *_frequencyLabel;
    NSTextField *_chargingLabel;
    NSTextField *_batteryDrainLabel;
    NSTextField *_temperatureLabel;
    NSTextField *_memoryLabel;
    NSImageView *_memoryPressureIcon;
    NSTextField *_memoryPressureLabel;
    NSTextField *_swapLabel;
    NSImageView *_cpuAlertIcon;
    NSTextField *_cpuAlertLabel;
    NSStackView *_cpuAlertRow;
    NSTextField *_appMemoryLabel;
    NSTextField *_appCPULabel;
    NSTextField *_coresLabel;
    NSButton *_loginCheckbox;
    NSTextField *_errorLabel;
}

- (void)loadView {
    NSView *container = [NSView new];
    _gpuLabel = [NSTextField labelWithString:@"GPU"];
    _cpuLabel = [NSTextField labelWithString:@"CPU"];
    _superLabel = [NSTextField labelWithString:@"CPU S"];
    _performanceLabel = [NSTextField labelWithString:@"CPU P"];
    _efficiencyLabel = [NSTextField labelWithString:@"CPU E"];
    _coreLegendLabel = [NSTextField labelWithString:@"E = Effizienzkerne  ·  P = Performancekerne"];
    _externalDriveLabel = [NSTextField wrappingLabelWithString:@"Extern: kein Laufwerk"];
    _performanceHeadroomLabel = [NSTextField labelWithString:@"Leistung: wird berechnet …"];
    _frequencyLabel = [NSTextField labelWithString:@"Takt: wird gemessen …"];
    _chargingLabel = [NSTextField labelWithString:@"Netzteil: nicht verbunden"];
    _batteryDrainLabel = [NSTextField labelWithString:@"Akku: wird gemessen …"];
    _temperatureLabel = [NSTextField labelWithString:@"Temperatur: wird gemessen …"];
    _memoryLabel = [NSTextField labelWithString:@"RAM"];
    _memoryPressureIcon = [self iconViewNamed:@"memory-pressure"];
    _memoryPressureLabel = [NSTextField labelWithString:@"Speicherdruck: wird gemessen …"];
    _swapLabel = [NSTextField labelWithString:@"SWAP: wird gemessen …"];
    _cpuAlertIcon = [self iconViewNamed:@"cpu-activity"];
    _cpuAlertLabel = [NSTextField wrappingLabelWithString:@""];
    _appMemoryLabel = [NSTextField wrappingLabelWithString:@"RAM pro App: wird gemessen …"];
    _appCPULabel = [NSTextField wrappingLabelWithString:@"CPU pro App: wird gemessen …"];
    _coresLabel = [NSTextField wrappingLabelWithString:@""];
    _gpuLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _cpuLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _superLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _performanceLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _efficiencyLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _coreLegendLabel.font = [NSFont systemFontOfSize:10];
    _coreLegendLabel.textColor = NSColor.secondaryLabelColor;
    _externalDriveLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    _externalDriveLabel.textColor = NSColor.systemBlueColor;
    _performanceHeadroomLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _frequencyLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _frequencyLabel.textColor = NSColor.secondaryLabelColor;
    _chargingLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _batteryDrainLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _temperatureLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _memoryLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _memoryPressureLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _swapLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _cpuAlertLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _appMemoryLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _appMemoryLabel.textColor = NSColor.secondaryLabelColor;
    _appCPULabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _appCPULabel.textColor = NSColor.secondaryLabelColor;
    _coresLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _coresLabel.textColor = NSColor.secondaryLabelColor;

    NSTextField *title = [NSTextField labelWithString:@"CoreBars"];
    title.font = [NSFont boldSystemFontOfSize:15];

    _loginCheckbox = [NSButton checkboxWithTitle:@"Beim Anmelden starten"
                                          target:self
                                          action:@selector(toggleLaunchAtLogin:)];
    _loginCheckbox.state = CBLoginItemManager.enabled ? NSControlStateValueOn : NSControlStateValueOff;

    _errorLabel = [NSTextField wrappingLabelWithString:@""];
    _errorLabel.font = [NSFont systemFontOfSize:10];
    _errorLabel.textColor = NSColor.systemRedColor;
    _errorLabel.hidden = YES;

    NSStackView *memoryPressureRow = [NSStackView stackViewWithViews:@[_memoryPressureIcon, _memoryPressureLabel]];
    memoryPressureRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    memoryPressureRow.alignment = NSLayoutAttributeCenterY;
    memoryPressureRow.spacing = 8;
    _cpuAlertRow = [NSStackView stackViewWithViews:@[_cpuAlertIcon, _cpuAlertLabel]];
    _cpuAlertRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _cpuAlertRow.alignment = NSLayoutAttributeCenterY;
    _cpuAlertRow.spacing = 8;
    _cpuAlertRow.hidden = YES;

    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    NSButton *quit = [NSButton buttonWithTitle:@"CoreBars beenden"
                                        target:self
                                        action:@selector(quit:)];
    quit.bezelStyle = NSBezelStyleRounded;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        title, _gpuLabel, _cpuLabel, _cpuAlertRow, _superLabel, _performanceLabel, _efficiencyLabel, _coreLegendLabel,
        _externalDriveLabel, _performanceHeadroomLabel, _frequencyLabel, _chargingLabel, _batteryDrainLabel, _temperatureLabel, _memoryLabel, memoryPressureRow, _swapLabel,
        _coresLabel, _appMemoryLabel, _appCPULabel,
        separator, _loginCheckbox, _errorLabel, quit
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:320],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
        [_memoryPressureIcon.widthAnchor constraintEqualToConstant:16],
        [_memoryPressureIcon.heightAnchor constraintEqualToConstant:16],
        [_cpuAlertIcon.widthAnchor constraintEqualToConstant:16],
        [_cpuAlertIcon.heightAnchor constraintEqualToConstant:16],
        [separator.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [quit.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    self.view = container;
}

- (NSImageView *)iconViewNamed:(NSString *)name {
    NSImageView *view = [NSImageView new];
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Assets"];
    NSImage *image = path != nil ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    image.template = YES;
    view.image = image;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    return view;
}

- (void)updateWithSnapshot:(CBSnapshot *)snapshot {
    if (!self.isViewLoaded) return;
    _gpuLabel.stringValue = isfinite(snapshot.gpuLoad)
        ? [NSString stringWithFormat:@"GPU:         %.0f %%", snapshot.gpuLoad * 100]
        : @"GPU:         wird gemessen …";
    _cpuLabel.stringValue = [NSString stringWithFormat:@"CPU gesamt: %.0f %%", snapshot.totalCPULoad * 100];
    _cpuAlertRow.hidden = snapshot.sustainedCPUProcess.length == 0;
    if (!_cpuAlertRow.hidden) {
        _cpuAlertLabel.stringValue = [NSString stringWithFormat:@"Dauerlast: %@ · %.0f %% seit %.0f s",
                                      snapshot.sustainedCPUProcess, snapshot.sustainedCPUPercent, snapshot.sustainedCPUSeconds];
        _cpuAlertLabel.textColor = NSColor.systemOrangeColor;
        _cpuAlertIcon.contentTintColor = NSColor.systemOrangeColor;
    }
    _superLabel.hidden = ![snapshot.coreTypes containsObject:@"S"];
    _superLabel.stringValue = [NSString stringWithFormat:@"CPU S:      %.0f %%", snapshot.superCPULoad * 100];
    _performanceLabel.hidden = ![snapshot.coreTypes containsObject:@"P"];
    _performanceLabel.stringValue = [NSString stringWithFormat:@"CPU P:      %.0f %%", snapshot.performanceCPULoad * 100];
    _efficiencyLabel.hidden = ![snapshot.coreTypes containsObject:@"E"];
    _efficiencyLabel.stringValue = [NSString stringWithFormat:@"CPU E:      %.0f %%", snapshot.efficiencyCPULoad * 100];
    if (snapshot.externalDrives.count == 0) {
        _externalDriveLabel.stringValue = @"Extern:     kein Laufwerk";
        _externalDriveLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        NSMutableArray<NSString *> *driveLines = [NSMutableArray arrayWithObject:@"Extern:"];
        for (CBExternalDrive *drive in snapshot.externalDrives) {
            NSString *free = [NSByteCountFormatter stringFromByteCount:(long long)drive.freeBytes
                                                            countStyle:NSByteCountFormatterCountStyleFile];
            NSString *total = [NSByteCountFormatter stringFromByteCount:(long long)drive.totalBytes
                                                             countStyle:NSByteCountFormatterCountStyleFile];
            [driveLines addObject:[NSString stringWithFormat:@"  %@  %@ frei / %@  ·  R %@  W %@  ·  %@",
                                   drive.name,
                                   free,
                                   total,
                                   CBRateText(drive.readBytesPerSecond),
                                   CBRateText(drive.writeBytesPerSecond),
                                   CBMbitRateText(drive.activityBytesPerSecond)]];
        }
        _externalDriveLabel.stringValue = [driveLines componentsJoinedByString:@"\n"];
        _externalDriveLabel.textColor = NSColor.systemBlueColor;
    }
    double effectivePerformance = snapshot.effectivePerformance;
    _performanceHeadroomLabel.stringValue = [NSString stringWithFormat:@"Leistung:   %.0f %%  (%@)", effectivePerformance * 100, CBThermalStateName(snapshot.thermalState)];
    _performanceHeadroomLabel.textColor = effectivePerformance > .85 ? NSColor.systemGreenColor :
        effectivePerformance > .65 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
    NSMutableArray<NSString *> *frequencyParts = [NSMutableArray array];
    if (isfinite(snapshot.pCpuFrequencyMHz)) {
        [frequencyParts addObject:[NSString stringWithFormat:@"P %.0f / %.0f MHz", snapshot.pCpuFrequencyMHz, snapshot.pCpuMaxFrequencyMHz]];
    }
    if (isfinite(snapshot.eCpuFrequencyMHz)) {
        [frequencyParts addObject:[NSString stringWithFormat:@"E %.0f / %.0f MHz", snapshot.eCpuFrequencyMHz, snapshot.eCpuMaxFrequencyMHz]];
    }
    if (frequencyParts.count > 0) {
        _frequencyLabel.stringValue = [NSString stringWithFormat:@"Takt: %@", [frequencyParts componentsJoinedByString:@"  ·  "]];
    } else {
        _frequencyLabel.stringValue = @"Takt: nicht verfügbar, nutze Temperatur/Thermal-State";
    }
    if (isfinite(snapshot.chargingWatts)) {
        _chargingLabel.stringValue = [NSString stringWithFormat:@"Netzteil:   %.1f W", snapshot.chargingWatts];
        _chargingLabel.textColor = snapshot.chargingWatts >= 25 ? NSColor.systemGreenColor : NSColor.systemYellowColor;
    } else if (snapshot.externalPowerConnected) {
        _chargingLabel.stringValue = @"Netzteil:   verbunden, Leistung unbekannt";
        _chargingLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        _chargingLabel.stringValue = @"Netzteil:   nicht verbunden";
        _chargingLabel.textColor = NSColor.secondaryLabelColor;
    }
    if (isfinite(snapshot.batteryDrainWatts)) {
        NSInteger drainLevel = snapshot.batteryDrainWatts < 12 ? 0 : (snapshot.batteryDrainWatts < 25 ? 1 : 2);
        _batteryDrainLabel.stringValue = [NSString stringWithFormat:@"Akku:       -%.1f W (%@)", snapshot.batteryDrainWatts, CBDrainStatus(drainLevel)];
        _batteryDrainLabel.textColor = drainLevel == 0 ? NSColor.systemGreenColor :
            (drainLevel == 1 ? NSColor.systemOrangeColor : NSColor.systemRedColor);
    } else if (snapshot.externalPowerConnected) {
        _batteryDrainLabel.stringValue = @"Akku:       kein Verbrauch";
        _batteryDrainLabel.textColor = NSColor.systemGreenColor;
    } else {
        _batteryDrainLabel.stringValue = @"Akku:       -0.0 W";
        _batteryDrainLabel.textColor = NSColor.systemGreenColor;
    }
    NSMutableArray<NSString *> *legend = [NSMutableArray array];
    if ([snapshot.coreTypes containsObject:@"S"]) [legend addObject:@"S = Superkerne"];
    if ([snapshot.coreTypes containsObject:@"P"]) [legend addObject:@"P = Performancekerne"];
    if ([snapshot.coreTypes containsObject:@"E"]) [legend addObject:@"E = Effizienzkerne"];
    _coreLegendLabel.stringValue = [legend componentsJoinedByString:@"  ·  "];
    if (isfinite(snapshot.cpuTemperature)) {
        _temperatureLabel.stringValue = [NSString stringWithFormat:@"CPU-Temperatur: %.1f °C", snapshot.cpuTemperature];
        _temperatureLabel.textColor = snapshot.cpuTemperature < 70 ? NSColor.systemGreenColor :
            snapshot.cpuTemperature < 85 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
    } else {
        _temperatureLabel.stringValue = @"CPU-Temperatur: wird gemessen …";
        _temperatureLabel.textColor = NSColor.secondaryLabelColor;
    }
    NSString *used = [NSByteCountFormatter stringFromByteCount:snapshot.memoryUsed countStyle:NSByteCountFormatterCountStyleMemory];
    NSString *total = [NSByteCountFormatter stringFromByteCount:snapshot.memoryTotal countStyle:NSByteCountFormatterCountStyleMemory];
    _memoryLabel.stringValue = [NSString stringWithFormat:@"RAM: %@ / %@  (%.0f %%)", used, total, snapshot.memoryLoad * 100];
    _memoryPressureLabel.stringValue = [NSString stringWithFormat:@"Speicherdruck: %@", CBMemoryPressureStatus(snapshot.memoryPressureLevel)];
    NSColor *pressureColor = snapshot.memoryPressureLevel == 0 ? NSColor.systemGreenColor :
        snapshot.memoryPressureLevel <= 2 && snapshot.memoryPressureLevel >= 1 ? NSColor.systemOrangeColor :
        snapshot.memoryPressureLevel >= 3 ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    _memoryPressureLabel.textColor = pressureColor;
    _memoryPressureIcon.contentTintColor = pressureColor;
    if (snapshot.swapTotal > 0) {
        NSString *swapUsed = [NSByteCountFormatter stringFromByteCount:(long long)snapshot.swapUsed countStyle:NSByteCountFormatterCountStyleMemory];
        NSString *swapTotal = [NSByteCountFormatter stringFromByteCount:(long long)snapshot.swapTotal countStyle:NSByteCountFormatterCountStyleMemory];
        _swapLabel.stringValue = [NSString stringWithFormat:@"SWAP: %@ / %@", swapUsed, swapTotal];
        _swapLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        _swapLabel.stringValue = @"SWAP: 0 MB";
        _swapLabel.textColor = NSColor.secondaryLabelColor;
    }
    if (snapshot.topMemoryConsumers.count == 0) {
        _appMemoryLabel.stringValue = @"RAM pro App: wird gemessen …";
    } else {
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"RAM pro App:"];
        for (CBMemoryConsumer *consumer in snapshot.topMemoryConsumers) {
            NSString *name = consumer.name.length > 22
                ? [[consumer.name substringToIndex:21] stringByAppendingString:@"…"]
                : consumer.name;
            NSString *amount = [NSByteCountFormatter stringFromByteCount:(long long)consumer.bytes
                                                              countStyle:NSByteCountFormatterCountStyleMemory];
            [lines addObject:[NSString stringWithFormat:@"  %@  %@", name, amount]];
        }
        _appMemoryLabel.stringValue = [lines componentsJoinedByString:@"\n"];
    }
    if (snapshot.topCPUConsumers.count == 0) {
        _appCPULabel.stringValue = @"CPU pro App: keine messbare Last";
    } else {
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"CPU pro App (100 % = ein Kern):"];
        for (CBCPUConsumer *consumer in snapshot.topCPUConsumers) {
            NSString *name = consumer.name.length > 30
                ? [[consumer.name substringToIndex:29] stringByAppendingString:@"…"]
                : consumer.name;
            [lines addObject:[NSString stringWithFormat:@"  %@  %.0f %%", name, consumer.percent]];
        }
        _appCPULabel.stringValue = [lines componentsJoinedByString:@"\n"];
    }
    NSMutableArray *cores = [NSMutableArray array];
    for (NSString *requestedType in [self orderedCoreTypesForSnapshot:snapshot]) {
        [snapshot.coreLoads enumerateObjectsUsingBlock:^(NSNumber *load, NSUInteger index, BOOL *stop) {
            NSString *type = index < snapshot.coreTypes.count ? snapshot.coreTypes[index] : @"?";
            if ([type isEqualToString:requestedType]) {
                [cores addObject:[NSString stringWithFormat:@"%@%lu %.0f%%", type, index + 1, load.doubleValue * 100]];
            }
        }];
    }
    _coresLabel.stringValue = [cores componentsJoinedByString:@"   "];
}

- (NSArray<NSString *> *)orderedCoreTypesForSnapshot:(CBSnapshot *)snapshot {
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *candidate in @[@"S", @"P", @"E"]) {
        if ([snapshot.coreTypes containsObject:candidate]) [ordered addObject:candidate];
    }
    for (NSString *type in snapshot.coreTypes) {
        if (![ordered containsObject:type]) [ordered addObject:type];
    }
    return ordered;
}

- (void)toggleLaunchAtLogin:(NSButton *)sender {
    NSError *error = nil;
    BOOL success = [CBLoginItemManager setEnabled:sender.state == NSControlStateValueOn error:&error];
    _errorLabel.hidden = success;
    if (!success) {
        _errorLabel.stringValue = [NSString stringWithFormat:@"Autostart: %@", error.localizedDescription];
        sender.state = CBLoginItemManager.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    }
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

@interface CBAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation CBAppDelegate {
    CBSystemMonitor *_monitor;
    CBTemperatureMonitor *_temperatureMonitor;
    CBStatusBarsView *_barsView;
    NSStatusItem *_statusItem;
    NSPopover *_popover;
    CBPopoverController *_popoverController;
    NSTimer *_timer;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!CBLoginItemManager.enabled) {
        NSError *loginError = nil;
        [CBLoginItemManager setEnabled:YES error:&loginError];
        if (loginError) {
            NSLog(@"CoreBars konnte Autostart nicht automatisch aktivieren: %@", loginError.localizedDescription);
        }
    }
    _monitor = [CBSystemMonitor new];
    _temperatureMonitor = [CBTemperatureMonitor new];
    CBSnapshot *snapshot = [_monitor sample];

    _barsView = [CBStatusBarsView new];
    _barsView.snapshot = snapshot;
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:_barsView.preferredWidth];
    NSStatusBarButton *button = _statusItem.button;
    _barsView.frame = button.bounds;
    _barsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [button addSubview:_barsView];

    __weak typeof(self) weakSelf = self;
    _barsView.clickHandler = ^{ [weakSelf togglePopover]; };
    _temperatureMonitor.updateHandler = ^{ [weakSelf update:nil]; };
    [_temperatureMonitor start];

    _popoverController = [CBPopoverController new];
    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.contentViewController = _popoverController;

    [self update:nil];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1
                                             target:self
                                           selector:@selector(update:)
                                           userInfo:nil
                                            repeats:YES];
}

- (void)update:(NSTimer *)timer {
    CBSnapshot *snapshot = [_monitor sample];
    snapshot.cpuTemperature = _temperatureMonitor.cpuTemperature;
    snapshot.gpuLoad = _temperatureMonitor.gpuLoad;
    snapshot.pCpuFrequencyMHz = _temperatureMonitor.pCpuFrequencyMHz;
    snapshot.eCpuFrequencyMHz = _temperatureMonitor.eCpuFrequencyMHz;
    snapshot.pCpuMaxFrequencyMHz = _temperatureMonitor.pCpuMaxFrequencyMHz;
    snapshot.eCpuMaxFrequencyMHz = _temperatureMonitor.eCpuMaxFrequencyMHz;
    snapshot.cpuFrequencyPerformance = _temperatureMonitor.cpuFrequencyPerformance;
    _barsView.snapshot = snapshot;
    CGFloat preferredWidth = _barsView.preferredWidth;
    if (fabs(_statusItem.length - preferredWidth) > 1) {
        _statusItem.length = preferredWidth;
        _barsView.frame = _statusItem.button.bounds;
    }
    [_popoverController updateWithSnapshot:snapshot];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_timer invalidate];
    [_temperatureMonitor stop];
}

- (void)togglePopover {
    if (_popover.shown) {
        [_popover performClose:nil];
    } else {
        [_popoverController updateWithSnapshot:_monitor.latestSnapshot];
        [_popover showRelativeToRect:_statusItem.button.bounds
                              ofView:_statusItem.button
                       preferredEdge:NSMinYEdge];
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        CBAppDelegate *delegate = [CBAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
