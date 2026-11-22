# =============================================================================
#  M1 dylib 构建（必须在 macOS 上跑；Windows 编译不了 iOS 二进制）
#
#  本地（有 Mac）:   make
#  云端（无 Mac）:   推 GitHub，Actions 自动编译并上传 artifact
#
#  产物: TiboPort.dylib（arm64, 已 ad-hoc 签名）
#        由 pack_clean.py 注入到官方包的 Payload/鹅鸭杀.app/TiboPort.dylib
#        主程序里对应新增一条 LC_LOAD_WEAK_DYLIB @executable_path/TiboPort.dylib
# =============================================================================

SDK_PATH := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC       := xcrun --sdk iphoneos clang

ARCH     := arm64
MIN_IOS  := 13.0

CFLAGS   := -arch $(ARCH) -isysroot $(SDK_PATH) -miphoneos-version-min=$(MIN_IOS) \
            -fobjc-arc -O2 -Wall -Wno-unused-function -Wno-deprecated-declarations
LDFLAGS  := -dynamiclib \
            -install_name @executable_path/TiboPort.dylib \
            -framework Foundation -framework UIKit -framework Security \
            -undefined dynamic_lookup

TARGET   := TiboPort.dylib
SRC      := src/TiboPort.mm

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^
	@echo "--- 产物信息 ---"
	@file $@
	@codesign -f -s - $@ && echo "ad-hoc 签名完成（全能签会重新签）"

clean:
	rm -f $(TARGET)

.PHONY: all clean
