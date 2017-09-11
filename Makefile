# Copyright (c) 2016 Cisco and/or its affiliates.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export WS_ROOT=$(CURDIR)
export BR=$(WS_ROOT)/build-root
CCACHE_DIR?=$(BR)/.ccache
GDB?=gdb
PLATFORM?=vpp
SAMPLE_PLUGIN?=no
export AESNI?=y

,:=,
define disable_plugins
$(if $(1), \
  "plugins {" \
  $(patsubst %,"plugin %_plugin.so { disable }",$(subst $(,), ,$(1))) \
  " }" \
  ,)
endef

MINIMAL_STARTUP_CONF="							\
unix { 									\
	interactive 							\
	cli-listen /run/vpp/cli.sock					\
	gid $(shell id -g)						\
	$(if $(wildcard startup.vpp),"exec startup.vpp",)		\
}									\
$(if $(DPDK_CONFIG), "dpdk { $(DPDK_CONFIG) }",)			\
$(call disable_plugins,$(DISABLED_PLUGINS))				\
"

GDB_ARGS= -ex "handle SIGUSR1 noprint nostop"

#
# OS Detection
#
# We allow Darwin (MacOS) for docs generation; VPP build will still fail.
ifneq ($(shell uname),Darwin)
OS_ID        = $(shell grep '^ID=' /etc/os-release | cut -f2- -d= | sed -e 's/\"//g')
OS_VERSION_ID= $(shell grep '^VERSION_ID=' /etc/os-release | cut -f2- -d= | sed -e 's/\"//g')
endif

ifeq ($(filter ubuntu debian,$(OS_ID)),$(OS_ID))
PKG=deb
else ifeq ($(filter rhel centos fedora opensuse,$(OS_ID)),$(OS_ID))
PKG=rpm
endif

# +libganglia1-dev if building the gmond plugin

DEB_DEPENDS  = curl build-essential autoconf automake bison libssl-dev ccache
DEB_DEPENDS += debhelper dkms git libtool libapr1-dev dh-systemd
DEB_DEPENDS += libconfuse-dev git-review exuberant-ctags cscope pkg-config
DEB_DEPENDS += lcov chrpath autoconf nasm indent libnuma-dev
DEB_DEPENDS += python-all python-dev python-virtualenv python-pip libffi6 check
ifeq ($(OS_VERSION_ID),14.04)
	DEB_DEPENDS += openjdk-8-jdk-headless
else ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-8)
	DEB_DEPENDS += openjdk-8-jdk-headless
	APT_ARGS = -t jessie-backports
else
	DEB_DEPENDS += default-jdk-headless
endif

RPM_DEPENDS  = redhat-lsb glibc-static java-1.8.0-openjdk-devel yum-utils
RPM_DEPENDS += apr-devel
RPM_DEPENDS += numactl-devel
RPM_DEPENDS += check
ifeq ($(OS_ID)-$(OS_VERSION_ID),fedora-25)
	RPM_DEPENDS += openssl-devel
	RPM_DEPENDS += python-devel
	RPM_DEPENDS += python2-virtualenv
	RPM_DEPENDS_GROUPS = 'C Development Tools and Libraries'
else ifeq ($(shell if [ "$(OS_ID)" = "fedora" ]; then test $(OS_VERSION_ID) -gt 25; echo $$?; fi),0)
	RPM_DEPENDS += compat-openssl10-devel
	RPM_DEPENDS += python2-devel
	RPM_DEPENDS += python2-virtualenv
	RPM_DEPENDS_GROUPS = 'C Development Tools and Libraries'
else
	RPM_DEPENDS += openssl-devel
	RPM_DEPENDS += python-devel
	RPM_DEPENDS += python-virtualenv
	RPM_DEPENDS_GROUPS = 'Development Tools'
endif

# +ganglia-devel if building the ganglia plugin

RPM_DEPENDS += chrpath libffi-devel rpm-build
ifeq ($(OS_ID),fedora)
	RPM_DEPENDS += nasm
else ifeq ($(findstring y,$(AESNI)),y)
	RPM_DEPENDS += https://kojipkgs.fedoraproject.org//packages/nasm/2.12.02/2.fc26/x86_64/nasm-2.12.02-2.fc26.x86_64.rpm
endif

RPM_SUSE_DEPENDS = autoconf automake bison ccache chrpath distribution-release gcc6 glibc-devel-static
RPM_SUSE_DEPENDS += java-1_8_0-openjdk-devel libopenssl-devel libtool lsb-release make openssl-devel
RPM_SUSE_DEPENDS += python-devel python-pip python-rpm-macros shadow nasm libnuma-devel python3

ifeq ($(filter rhel centos,$(OS_ID)),$(OS_ID))
	RPM_DEPENDS += python34
else
	RPM_DEPENDS += python3
endif

ifneq ($(wildcard $(STARTUP_DIR)/startup.conf),)
        STARTUP_CONF ?= $(STARTUP_DIR)/startup.conf
endif

ifeq ($(findstring y,$(UNATTENDED)),y)
CONFIRM=-y
FORCE=--force-yes
endif

TARGETS = vpp

ifneq ($(SAMPLE_PLUGIN),no)
TARGETS += sample-plugin
endif

.PHONY: help bootstrap wipe wipe-release build build-release rebuild rebuild-release
.PHONY: run run-release debug debug-release build-vat run-vat pkg-deb pkg-rpm
.PHONY: ctags cscope
.PHONY: test test-debug retest retest-debug test-doc test-wipe-doc test-help test-wipe
.PHONY: test-cov test-wipe-cov

help:
	@echo "Make Targets:"
	@echo " bootstrap           - prepare tree for build"
	@echo " install-dep         - install software dependencies"
	@echo " wipe                - wipe all products of debug build "
	@echo " wipe-release        - wipe all products of release build "
	@echo " build               - build debug binaries"
	@echo " build-release       - build release binaries"
	@echo " build-coverity      - build coverity artifacts"
	@echo " rebuild             - wipe and build debug binares"
	@echo " rebuild-release     - wipe and build release binares"
	@echo " run                 - run debug binary"
	@echo " run-release         - run release binary"
	@echo " debug               - run debug binary with debugger"
	@echo " debug-release       - run release binary with debugger"
	@echo " test                - build and run (basic) functional tests"
	@echo " test-debug          - build and run (basic) functional tests (debug build)"
	@echo " test-all            - build and run (all) functional tests"
	@echo " test-all-debug      - build and run (all) functional tests (debug build)"
	@echo " test-shell          - enter shell with test environment"
	@echo " test-shell-debug    - enter shell with test environment (debug build)"
	@echo " test-wipe           - wipe files generated by unit tests"
	@echo " retest              - run functional tests"
	@echo " retest-debug        - run functional tests (debug build)"
	@echo " test-help           - show help on test framework"
	@echo " run-vat             - run vpp-api-test tool"
	@echo " pkg-deb             - build DEB packages"
	@echo " pkg-rpm             - build RPM packages"
	@echo " dpdk-install-dev    - install DPDK development packages"
	@echo " ctags               - (re)generate ctags database"
	@echo " gtags               - (re)generate gtags database"
	@echo " cscope              - (re)generate cscope database"
	@echo " checkstyle          - check coding style"
	@echo " fixstyle            - fix coding style"
	@echo " doxygen             - (re)generate documentation"
	@echo " bootstrap-doxygen   - setup Doxygen dependencies"
	@echo " wipe-doxygen        - wipe all generated documentation"
	@echo " test-doc            - generate documentation for test framework"
	@echo " test-wipe-doc       - wipe documentation for test framework"
	@echo " test-cov            - generate code coverage report for test framework"
	@echo " test-wipe-cov       - wipe code coverage report for test framework"
	@echo " test-checkstyle     - check PEP8 compliance for test framework"
	@echo ""
	@echo "Make Arguments:"
	@echo " V=[0|1]                  - set build verbosity level"
	@echo " STARTUP_CONF=<path>      - startup configuration file"
	@echo "                            (e.g. /etc/vpp/startup.conf)"
	@echo " STARTUP_DIR=<path>       - startup drectory (e.g. /etc/vpp)"
	@echo "                            It also sets STARTUP_CONF if"
	@echo "                            startup.conf file is present"
	@echo " GDB=<path>               - gdb binary to use for debugging"
	@echo " PLATFORM=<name>          - target platform. default is vpp"
	@echo " TEST=<filter>            - apply filter to test set, see test-help"
	@echo " DPDK_CONFIG=<conf>       - add specified dpdk config commands to"
	@echo "                            autogenerated startup.conf"
	@echo "                            (e.g. \"no-pci\" )"
	@echo " SAMPLE_PLUGIN=yes        - in addition build/run/debug sample plugin"
	@echo " DISABLED_PLUGINS=<list>  - comma separated list of plugins which"
	@echo "                            should not be loaded"
	@echo ""
	@echo "Current Argument Values:"
	@echo " V                 = $(V)"
	@echo " STARTUP_CONF      = $(STARTUP_CONF)"
	@echo " STARTUP_DIR       = $(STARTUP_DIR)"
	@echo " GDB               = $(GDB)"
	@echo " PLATFORM          = $(PLATFORM)"
	@echo " DPDK_VERSION      = $(DPDK_VERSION)"
	@echo " DPDK_CONFIG       = $(DPDK_CONFIG)"
	@echo " SAMPLE_PLUGIN     = $(SAMPLE_PLUGIN)"
	@echo " DISABLED_PLUGINS  = $(DISABLED_PLUGINS)"

$(BR)/.bootstrap.ok:
ifeq ($(findstring y,$(UNATTENDED)),y)
	make install-dep
endif
ifeq ($(filter ubuntu debian,$(OS_ID)),$(OS_ID))
	@MISSING=$$(apt-get install -y -qq -s $(DEB_DEPENDS) | grep "^Inst ") ; \
	if [ -n "$$MISSING" ] ; then \
	  echo "\nPlease install missing packages: \n$$MISSING\n" ; \
	  echo "by executing \"make install-dep\"\n" ; \
	  exit 1 ; \
	fi ; \
	exit 0
else ifneq ("$(wildcard /etc/redhat-release)","")
	@for i in $(RPM_DEPENDS) ; do \
	    RPM=$$(basename -s .rpm "$${i##*/}" | cut -d- -f1,2,3)  ;	\
	    MISSING+=$$(rpm -q $$RPM | grep "^package")	   ;    \
	done							   ;	\
	if [ -n "$$MISSING" ] ; then \
	  echo "Please install missing RPMs: \n$$MISSING\n" ; \
	  echo "by executing \"make install-dep\"\n" ; \
	  exit 1 ; \
	fi ; \
	exit 0
endif
	@echo "SOURCE_PATH = $(WS_ROOT)"                   > $(BR)/build-config.mk
	@echo "#!/bin/bash\n"                              > $(BR)/path_setup
	@echo 'export PATH=$(BR)/tools/ccache-bin:$$PATH' >> $(BR)/path_setup
	@echo 'export PATH=$(BR)/tools/bin:$$PATH'        >> $(BR)/path_setup
	@echo 'export CCACHE_DIR=$(CCACHE_DIR)'           >> $(BR)/path_setup

ifeq ("$(wildcard /usr/bin/ccache )","")
	@echo "WARNING: Please install ccache AYEC and re-run this script"
else
	@rm -rf $(BR)/tools/ccache-bin
	@mkdir -p $(BR)/tools/ccache-bin
	@ln -s /usr/bin/ccache $(BR)/tools/ccache-bin/gcc
	@ln -s /usr/bin/ccache $(BR)/tools/ccache-bin/g++
endif
	@make -C $(BR) V=$(V) is_build_tool=yes tools-install
	@touch $@

bootstrap: $(BR)/.bootstrap.ok

install-dep:
ifeq ($(filter ubuntu debian,$(OS_ID)),$(OS_ID))
ifeq ($(OS_VERSION_ID),14.04)
	@sudo -E apt-get $(CONFIRM) $(FORCE) install software-properties-common
	@sudo -E add-apt-repository ppa:openjdk-r/ppa $(CONFIRM)
endif
ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-8)
	@grep -q jessie-backports /etc/apt/sources.list /etc/apt/sources.list.d/* 2> /dev/null \
           || ( echo "Please install jessie-backports" ; exit 1 )
endif
	@sudo -E apt-get update
	@sudo -E apt-get $(APT_ARGS) $(CONFIRM) $(FORCE) install $(DEB_DEPENDS)
else ifneq ("$(wildcard /etc/redhat-release)","")
	@sudo -E yum groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E yum install $(CONFIRM) $(RPM_DEPENDS)
	@sudo -E debuginfo-install $(CONFIRM) glibc openssl-libs zlib
else ifeq ($(filter opensuse,$(OS_ID)),$(OS_ID))
	@sudo -E zypper -n install -y $(RPM_SUSE_DEPENDS)
else
	$(error "This option currently works only on Ubuntu, Debian or Centos systems")
endif

define make
	@make -C $(BR) PLATFORM=$(PLATFORM) TAG=$(1) $(2)
endef

$(BR)/scripts/.version:
ifneq ("$(wildcard /etc/redhat-release)","")
	$(shell $(BR)/scripts/version rpm-string > $(BR)/scripts/.version)
else
	$(shell $(BR)/scripts/version > $(BR)/scripts/.version)
endif

DIST_FILE = $(BR)/vpp-$(shell src/scripts/version).tar
DIST_SUBDIR = vpp-$(shell src/scripts/version|cut -f1 -d-)

dist:
	@if git rev-parse 2> /dev/null ; then \
	    git archive \
	      --prefix=$(DIST_SUBDIR)/ \
	      --format=tar \
	      -o $(DIST_FILE) \
	    HEAD ; \
	    git describe > $(BR)/.version ; \
	else \
	    (cd .. ; tar -cf $(DIST_FILE) $(DIST_SUBDIR) --exclude=*.tar) ; \
	    src/scripts/version > $(BR)/.version ; \
	fi
	@tar --append \
	  --file $(DIST_FILE) \
	  --transform='s,.*/.version,$(DIST_SUBDIR)/src/scripts/.version,' \
	  $(BR)/.version
	@$(RM) $(BR)/.version $(DIST_FILE).xz
	@xz -v --threads=0 $(DIST_FILE)
	@$(RM) $(BR)/vpp-latest.tar.xz
	@ln -rs $(DIST_FILE).xz $(BR)/vpp-latest.tar.xz

build: $(BR)/.bootstrap.ok
	$(call make,$(PLATFORM)_debug,$(addsuffix -install,$(TARGETS)))

wipedist:
	@$(RM) $(BR)/*.tar.xz

wipe: wipedist $(BR)/.bootstrap.ok
	$(call make,$(PLATFORM)_debug,$(addsuffix -wipe,$(TARGETS)))

rebuild: wipe build

build-release: $(BR)/.bootstrap.ok
	$(call make,$(PLATFORM),$(addsuffix -install,$(TARGETS)))

wipe-release: $(BR)/.bootstrap.ok
	$(call make,$(PLATFORM),$(addsuffix -wipe,$(TARGETS)))

rebuild-release: wipe-release build-release

export VPP_PYTHON_PREFIX=$(BR)/python

libexpand = $(subst $(subst ,, ),:,$(foreach lib,$(1),$(BR)/install-$(2)-native/vpp/$(lib)/$(3)))

define test
	$(if $(filter-out $(3),retest),make -C $(BR) PLATFORM=$(1) TAG=$(2) vpp-install,)
	$(eval libs:=lib lib64)
	make -C test \
	  TEST_DIR=$(WS_ROOT)/test \
	  VPP_TEST_BUILD_DIR=$(BR)/build-$(2)-native \
	  VPP_TEST_BIN=$(BR)/install-$(2)-native/vpp/bin/vpp \
	  VPP_TEST_PLUGIN_PATH=$(call libexpand,$(libs),$(2),vpp_plugins) \
	  VPP_TEST_INSTALL_PATH=$(BR)/install-$(2)-native/ \
	  LD_LIBRARY_PATH=$(call libexpand,$(libs),$(2),) \
	  EXTENDED_TESTS=$(EXTENDED_TESTS) \
	  PYTHON=$(PYTHON) \
	  $(3)
endef

test: bootstrap
	$(call test,vpp,vpp,test)

test-debug: bootstrap
	$(call test,vpp,vpp_debug,test)

test-all: bootstrap
	$(eval EXTENDED_TESTS=yes)
	$(call test,vpp,vpp,test)

test-all-debug: bootstrap
	$(eval EXTENDED_TESTS=yes)
	$(call test,vpp,vpp_debug,test)

test-help:
	@make -C test help

test-wipe:
	@make -C test wipe

test-shell: bootstrap
	$(call test,vpp,vpp,shell)

test-shell-debug: bootstrap
	$(call test,vpp,vpp_debug,shell)

test-doc:
	@make -C test doc

test-wipe-doc:
	@make -C test wipe-doc

test-cov: bootstrap
	$(eval EXTENDED_TESTS=yes)
	$(call test,vpp,vpp_gcov,cov)

test-wipe-cov:
	@make -C test wipe-cov

test-checkstyle:
	@make -C test checkstyle

retest:
	$(call test,vpp,vpp,retest)

retest-debug:
	$(call test,vpp,vpp_debug,retest)

STARTUP_DIR ?= $(PWD)
ifeq ("$(wildcard $(STARTUP_CONF))","")
define run
	@echo "WARNING: STARTUP_CONF not defined or file doesn't exist."
	@echo "         Running with minimal startup config: $(MINIMAL_STARTUP_CONF)\n"
	@cd $(STARTUP_DIR) && \
	  sudo $(2) $(1)/vpp/bin/vpp $(MINIMAL_STARTUP_CONF) \
	    plugin_path $(subst $(subst ,, ),:,$(wildcard $(1)/*/lib*/vpp_plugins))
endef
else
define run
	@cd $(STARTUP_DIR) && \
	  sudo $(2) $(1)/vpp/bin/vpp $(shell cat $(STARTUP_CONF) | sed -e 's/#.*//') \
	    plugin_path $(subst $(subst ,, ),:,$(wildcard $(1)/*/lib*/vpp_plugins))
endef
endif

%.files: .FORCE
	@find . \( -name '*\.[chyS]' -o -name '*\.java' -o -name '*\.lex' \) -and \
		\( -not -path './build-root*' -o -path \
		'./build-root/build-vpp_debug-native/dpdk*' \) > $@

.FORCE:

run:
	$(call run, $(BR)/install-$(PLATFORM)_debug-native)

run-release:
	$(call run, $(BR)/install-$(PLATFORM)-native)

debug:
	$(call run, $(BR)/install-$(PLATFORM)_debug-native,$(GDB) $(GDB_ARGS) --args)

build-coverity: 
	$(call make,$(PLATFORM)_coverity,install-packages)

debug-release:
	$(call run, $(BR)/install-$(PLATFORM)-native,$(GDB) $(GDB_ARGS) --args)

build-vat:
	$(call make,$(PLATFORM)_debug,vpp-api-test-install)

run-vat:
	@sudo $(BR)/install-$(PLATFORM)_debug-native/vpp/bin/vpp_api_test

pkg-deb:
	$(call make,$(PLATFORM),install-deb)

pkg-rpm: dist
	make -C extras/rpm

pkg-srpm: dist
	make -C extras/rpm srpm

dpdk-install-dev:
	make -C dpdk install-$(PKG)

ctags: ctags.files
	@ctags --totals --tag-relative -L $<
	@rm $<

gtags: ctags
	@gtags --gtagslabel=ctags

cscope: cscope.files
	@cscope -b -q -v

checkstyle:
	@build-root/scripts/checkstyle.sh

fixstyle:
	@build-root/scripts/checkstyle.sh --fix

#
# Build the documentation
#

# Doxygen configuration and our utility scripts
export DOXY_DIR ?= $(WS_ROOT)/doxygen

define make-doxy
	@OS_ID="$(OS_ID)" make -C $(DOXY_DIR) $@
endef

.PHONY: bootstrap-doxygen doxygen wipe-doxygen

bootstrap-doxygen:
	$(call make-doxy)

doxygen:
	$(call make-doxy)

wipe-doxygen:
	$(call make-doxy)

define banner
	@echo "========================================================================"
	@echo " $(1)"
	@echo "========================================================================"
	@echo " "
endef

verify: install-dep $(BR)/.bootstrap.ok dpdk-install-dev
	$(call banner,"Building for PLATFORM=vpp using gcc")
	@make -C build-root PLATFORM=vpp TAG=vpp wipe-all install-packages
ifeq ($(OS_ID)-$(OS_VERSION_ID),ubuntu-16.04)
	$(call banner,"Installing dependencies")
	@sudo -E apt-get update
	@sudo -E apt-get $(CONFIRM) $(FORCE) install clang
	$(call banner,"Building for PLATFORM=vpp using clang")
	@make -C build-root CC=clang PLATFORM=vpp TAG=vpp_clang wipe-all install-packages
endif
	$(call banner,"Building sample-plugin")
	@make -C build-root PLATFORM=vpp TAG=vpp sample-plugin-install
	$(call banner,"Building $(PKG) packages")
	@make pkg-$(PKG)
ifeq ($(OS_ID)-$(OS_VERSION_ID),ubuntu-16.04)
	@make COMPRESS_FAILED_TEST_LOGS=yes test
endif


