#CC?=	/usr/bin/cc

all: build/imtui.stamp

build/imtui.stamp:
	mkdir -p build/imtui
	cd build/imtui && cmake ../../vendor/imtui/ -DBUILD_SHARED_LIBS=OFF -DIMTUI_SUPPORT_CURL=OFF -DIMTUI_SUPPORT_CURL=OFF
	cd build/imtui && make -j $(nproc)
	touch build/sqlite3.stamp

clean:
	rm -rf build/imtui*

