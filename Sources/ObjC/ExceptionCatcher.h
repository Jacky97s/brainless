#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// 執行 block；若系統丟出 NSException，回傳它的說明文字，否則回傳 nil
NSString * _Nullable BLCatchException(void (NS_NOESCAPE ^block)(void));
NS_ASSUME_NONNULL_END
