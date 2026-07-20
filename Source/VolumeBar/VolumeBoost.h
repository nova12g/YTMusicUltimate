// VolumeBoost.h
// Adds a forced per-channel (Left/Right) volume boost to YTMusicUltimate,
// with a safety cap of 1.5x and an opt-in "Danger Zone" that raises the cap
// to 2.0x only after an explicit 10-second confirmation.
//
// NOTE ON HEARING SAFETY: gain above unity (1.0) pushes samples past 0 dBFS
// and is hard-clamped here to avoid runaway distortion, but it can still be
// LOUD. The 1.5x default cap and the Danger-Zone friction are deliberate
// guards. Gains reset to 1.0x and Danger Zone resets to OFF on every launch.
//
// PLACEMENT: this file and VolumeBoost.x live in the TOP LEVEL of Source/,
// not in a subfolder. The Makefile only globs `Source/*.x` (top level) and
// `find Source -name '*.m'`; a `.xm` file or a file in a subfolder would be
// skipped by the build.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>

@interface VBBoostController : NSObject
@property (nonatomic, assign) float leftGain;    // 1.0 ... maxGain
@property (nonatomic, assign) float rightGain;   // 1.0 ... maxGain
@property (nonatomic, assign, readonly) BOOL dangerZone; // NO -> cap 1.5, YES -> cap 2.0
+ (instancetype)shared;
- (float)maxGain;                 // 1.5 normally, 2.0 in Danger Zone
- (void)setLeftGainClamped:(float)g;
- (void)setRightGainClamped:(float)g;
- (void)setDangerZone:(BOOL)dz;   // also re-clamps both gains to the new max
@end

@interface VBBoostPanel : UIView
@end
