BOARD_FQBN = esp32:esp32:esp32c6:UploadSpeed=921600,CDCOnBoot=cdc,CPUFreq=160,FlashFreq=80,FlashMode=qio,FlashSize=4M,PartitionScheme=huge_app,DebugLevel=none,EraseFlash=none
PORT       = /dev/ttyACM0
LIBS       = /home/jw/Arduino/libraries
BUILD_DIR  = ./build

.PHONY: all compile upload monitor flash dev clean

all: compile

compile:
	arduino-cli compile --fqbn $(BOARD_FQBN) --libraries $(LIBS) --build-path $(BUILD_DIR) .

upload:
	arduino-cli upload --fqbn $(BOARD_FQBN) --port $(PORT) --build-path $(BUILD_DIR) .

monitor:
	tio $(PORT) -b 115200

flash: compile upload

dev: compile upload monitor

clean:
	rm -rf $(BUILD_DIR)
