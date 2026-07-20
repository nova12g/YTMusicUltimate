// VolumeBoost.xm  —  drop-in feature for YTMusicUltimate
// See VolumeBoost.h for the safety rationale.
//
// Mechanism: an MTAudioProcessingTap is attached to the app's AVPlayerItems
// and multiplies each channel's PCM samples by an independent L/R gain factor.
// The UI is a floating panel added to the now-playing (YTMWatchView) screen.
//
// IMPORTANT CAVEAT (read before trusting the boost): MTAudioProcessingTap is
// NOT supported on HLS / live-streamed assets. YouTube Music streams via HLS,
// so on streamed tracks the tap may attach to no audio track and the boost
// becomes a silent no-op. The UI + Danger-Zone logic still work; if the tap
// does not bite, the gain factor in VBBoostController is the single point to
// re-wire onto whatever player method proves controllable on your build.

#import "VolumeBoost.h"
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// Safety limits
// ---------------------------------------------------------------------------
static const float        kSafeMaxGain        = 1.5f;  // default hard cap
static const float        kDangerMaxGain      = 2.0f;  // only after confirm
static const NSInteger    kDangerConfirmSecs  = 10;    // countdown length

static BOOL YTMU(NSString *key) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [d[key] boolValue];
}
// Gate: master switch on. (Optionally also require a "volBoost" toggle — see
// INTEGRATION.md — by changing this to && YTMU(@"volBoost").)
static BOOL boostEnabled(void) { return YTMU(@"YTMUltimateIsEnabled"); }

static inline float clampSample(float x) {
    if (x >  1.0f) return  1.0f;
    if (x < -1.0f) return -1.0f;
    return x;
}

// ---------------------------------------------------------------------------
// Gain controller (single source of truth for the tap and the UI)
// ---------------------------------------------------------------------------
@implementation VBBoostController
+ (instancetype)shared {
    static VBBoostController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [VBBoostController new];
        s->_leftGain  = 1.0f;   // safe defaults every launch
        s->_rightGain = 1.0f;
        s->_dangerZone = NO;
    });
    return s;
}
- (float)maxGain { return _dangerZone ? kDangerMaxGain : kSafeMaxGain; }
- (void)setLeftGainClamped:(float)g  { _leftGain  = fmaxf(1.0f, fminf(g, [self maxGain])); }
- (void)setRightGainClamped:(float)g { _rightGain = fmaxf(1.0f, fminf(g, [self maxGain])); }
- (void)setDangerZone:(BOOL)dz {
    _dangerZone = dz;
    // Leaving Danger Zone must not strand a >1.5x boost.
    [self setLeftGainClamped:_leftGain];
    [self setRightGainClamped:_rightGain];
}
@end

// ---------------------------------------------------------------------------
// MTAudioProcessingTap — applies per-channel gain to the live PCM buffer
// ---------------------------------------------------------------------------
static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storageOut) { *storageOut = clientInfo; }
static void tapFinalize(MTAudioProcessingTapRef tap) {}
static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *fmt) {}
static void tapUnprepare(MTAudioProcessingTapRef tap) {}

static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *bufList,
                       CMItemCount *numOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numFrames, bufList, flagsOut, NULL, numOut);
    if (st != noErr) return;

    VBBoostController *c = [VBBoostController shared];
    float lg = c.leftGain, rg = c.rightGain;
    if (lg == 1.0f && rg == 1.0f) return; // no work

    for (UInt32 b = 0; b < bufList->mNumberBuffers; b++) {
        AudioBuffer buf = bufList->mBuffers[b];
        float *samp = (float *)buf.mData;
        if (!samp) continue;
        UInt32 n = buf.mDataByteSize / (UInt32)sizeof(float);

        if (buf.mNumberChannels == 2) {
            // Interleaved: L, R, L, R ...
            for (UInt32 i = 0; i + 1 < n; i += 2) {
                samp[i]     = clampSample(samp[i]     * lg);
                samp[i + 1] = clampSample(samp[i + 1] * rg);
            }
        } else {
            // Planar: buffer 0 = Left, buffer 1 = Right (mono buffers)
            float g = (b == 0) ? lg : rg;
            for (UInt32 i = 0; i < n; i++) samp[i] = clampSample(samp[i] * g);
        }
    }
}

static AVAudioMix *VBMakeBoostMix(AVAsset *asset) {
    if (!asset) return nil;
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) return nil; // e.g. HLS with no synchronous audio track

    MTAudioProcessingTapCallbacks cb;
    cb.version    = kMTAudioProcessingTapCallbacksVersion_0;
    cb.clientInfo = NULL;
    cb.init       = tapInit;
    cb.finalize   = tapFinalize;
    cb.prepare    = tapPrepare;
    cb.unprepare  = tapUnprepare;
    cb.process    = tapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus s = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb,
                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    if (s != noErr || !tap) return nil;

    AVMutableAudioMixInputParameters *p =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
    p.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[p];
    return mix;
}

%hook AVPlayerItem
- (void)setAudioMix:(AVAudioMix *)audioMix {
    if (boostEnabled() && audioMix == nil) {
        AVAudioMix *m = VBMakeBoostMix(self.asset);
        if (m) { %orig(m); return; }
    }
    %orig;
}
+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    AVPlayerItem *item = %orig;
    if (boostEnabled() && item && item.audioMix == nil) {
        AVAudioMix *m = VBMakeBoostMix(asset);
        if (m) item.audioMix = m;
    }
    return item;
}
%end

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------
static UIViewController *VBTopViewController(void) {
    UIWindow *w = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) { w = win; break; }
    }
    if (!w) w = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ---------------------------------------------------------------------------
// Floating boost panel: L slider, R slider, and the Danger Zone switch
// ---------------------------------------------------------------------------
@implementation VBBoostPanel {
    UISlider *_left;
    UISlider *_right;
    UILabel  *_leftVal;
    UILabel  *_rightVal;
    UISwitch *_danger;
    NSTimer  *_countdown;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        self.layer.cornerRadius = 14;
        self.userInteractionEnabled = YES;

        UILabel *title = [self label:@"VOLUME BOOST" size:11 weight:UIFontWeightBold];
        title.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        title.frame = CGRectMake(14, 8, frame.size.width - 28, 14);
        [self addSubview:title];

        _left    = [self makeSlider];
        _leftVal = [self label:@"1.00x" size:12 weight:UIFontWeightSemibold];
        [self layoutRow:@"L" slider:_left value:_leftVal y:28];

        _right    = [self makeSlider];
        _rightVal = [self label:@"1.00x" size:12 weight:UIFontWeightSemibold];
        [self layoutRow:@"R" slider:_right value:_rightVal y:60];

        UILabel *dz = [self label:@"Danger Zone (up to 2x)" size:12 weight:UIFontWeightMedium];
        dz.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.3 alpha:1.0];
        dz.frame = CGRectMake(14, 92, frame.size.width - 80, 20);
        [self addSubview:dz];

        _danger = [[UISwitch alloc] init];
        _danger.onTintColor = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0];
        _danger.transform = CGAffineTransformMakeScale(0.8, 0.8);
        _danger.frame = CGRectMake(frame.size.width - 62, 88, 50, 28);
        [_danger addTarget:self action:@selector(dangerToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_danger];

        [self refreshRanges];
    }
    return self;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)w {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = [UIColor whiteColor];
    return l;
}

- (UISlider *)makeSlider {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = 1.0f;
    s.maximumValue = kSafeMaxGain;
    s.value = 1.0f;
    s.minimumTrackTintColor = [UIColor whiteColor];
    [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (void)layoutRow:(NSString *)tag slider:(UISlider *)slider value:(UILabel *)value y:(CGFloat)y {
    CGFloat w = self.frame.size.width;
    UILabel *t = [self label:tag size:12 weight:UIFontWeightBold];
    t.frame = CGRectMake(14, y, 16, 24);
    [self addSubview:t];
    slider.frame = CGRectMake(36, y, w - 36 - 70, 24);
    [self addSubview:slider];
    value.frame = CGRectMake(w - 62, y, 52, 24);
    value.textAlignment = NSTextAlignmentRight;
    [self addSubview:value];
}

- (void)sliderChanged:(UISlider *)s {
    VBBoostController *c = [VBBoostController shared];
    if (s == _left)  [c setLeftGainClamped:s.value];
    if (s == _right) [c setRightGainClamped:s.value];
    _leftVal.text  = [NSString stringWithFormat:@"%.2fx", c.leftGain];
    _rightVal.text = [NSString stringWithFormat:@"%.2fx", c.rightGain];
    _left.value  = c.leftGain;   // reflect any clamping
    _right.value = c.rightGain;
}

- (void)refreshRanges {
    VBBoostController *c = [VBBoostController shared];
    _left.maximumValue  = c.maxGain;
    _right.maximumValue = c.maxGain;
    _left.value  = c.leftGain;
    _right.value = c.rightGain;
    _leftVal.text  = [NSString stringWithFormat:@"%.2fx", c.leftGain];
    _rightVal.text = [NSString stringWithFormat:@"%.2fx", c.rightGain];
    _danger.on = c.dangerZone;
}

// ---- Danger Zone: 10-second gated confirmation --------------------------
- (NSString *)dangerMessageForSeconds:(NSInteger)secs {
    return [NSString stringWithFormat:
        @"This raises the volume cap to 2x, past the level the earbuds are "
        @"tuned for. Loud audio can permanently damage your hearing.\n\n"
        @"You can confirm in %ld second%@…", (long)secs, secs == 1 ? @"" : @"s"];
}

- (void)dangerToggled:(UISwitch *)sw {
    if (!sw.isOn) {                             // turning OFF is immediate
        [_countdown invalidate];
        [[VBBoostController shared] setDangerZone:NO];
        [self refreshRanges];
        return;
    }

    sw.on = NO; // stay off until the countdown completes and user confirms

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"⚠️ Danger Zone"
        message:[self dangerMessageForSeconds:kDangerConfirmSecs]
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
            [self->_countdown invalidate];
        }];

    UIAlertAction *sure = [UIAlertAction actionWithTitle:@"I'm sure"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self->_countdown invalidate];
            [[VBBoostController shared] setDangerZone:YES];
            sw.on = YES;
            [self refreshRanges];
        }];
    sure.enabled = NO;                          // locked during the countdown

    [a addAction:cancel];
    [a addAction:sure];

    __block NSInteger remaining = kDangerConfirmSecs;
    _countdown = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        remaining--;
        if (remaining <= 0) {
            a.message = @"Boost can exceed safe limits and risk hearing damage. "
                        @"Press \"I'm sure\" to enable 2x boost.";
            sure.enabled = YES;
            [t invalidate];
        } else {
            a.message = [self dangerMessageForSeconds:remaining];
        }
    }];

    [VBTopViewController() presentViewController:a animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// Inject the panel into the now-playing screen (same host view the stock
// volume bar uses). Guarded by an associated object so it is added once.
// ---------------------------------------------------------------------------
static void *kVBPanelKey = &kVBPanelKey;

@interface YTMWatchView : UIView
@end

%hook YTMWatchView
- (void)layoutSubviews {
    %orig;
    if (!boostEnabled()) return;
    if (objc_getAssociatedObject(self, kVBPanelKey)) return;

    CGFloat w = self.frame.size.width - 24;
    VBBoostPanel *panel = [[VBBoostPanel alloc] initWithFrame:CGRectMake(12, 72, w, 122)];
    objc_setAssociatedObject(self, kVBPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addSubview:panel];
}
%end
