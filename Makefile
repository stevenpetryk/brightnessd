SWIFTC ?= $(shell xcrun -f swiftc 2>/dev/null || command -v swiftc || echo swiftc)
PLIST = com.stevenpetryk.brightnessd.plist
AGENT = $(HOME)/Library/LaunchAgents/$(PLIST)

all: m1ddc/m1ddc brightnessd

brightnessd: main.swift
	$(SWIFTC) -O main.swift -o brightnessd

m1ddc/m1ddc: m1ddc/sources/*.m m1ddc/headers/*.h
	$(MAKE) -C m1ddc

install: all
	sed "s|@BINARY@|$(CURDIR)/brightnessd|" $(PLIST).in > $(AGENT)
	launchctl unload $(AGENT) 2>/dev/null; launchctl load $(AGENT)

uninstall:
	launchctl unload $(AGENT) 2>/dev/null; rm -f $(AGENT)

clean:
	rm -f brightnessd m1ddc/m1ddc

.PHONY: all install uninstall clean
