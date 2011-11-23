
SOURCE_DIRS=src
VPATH=$(SOURCE_DIRS) # http://www.ipp.mpg.de/~dpc/gmake/make_27.html#SEC26
EBIN_DIR=ebin
ET_DIR=et

CONTRIBS = $(shell echo `ls -d contrib/*/ 2>/dev/null`)
CONTRIB_PATH=$(foreach dir, ${CONTRIBS}, -pa $(dir)ebin)
CONTRIB_INCLUDES=$(foreach dir, ${CONTRIBS}, -I"$(dir)include")

INCLUDE_DIRS=include

INCLUDES=$(foreach dir, $(INCLUDE_DIRS), $(wildcard $(dir)/*.hrl))

INCLUDE_FLAGS += $(foreach dir, $(INCLUDE_DIRS), -I $(dir))

SOURCES=$(foreach dir, $(SOURCE_DIRS), $(wildcard $(dir)/*.erl))
TARGETS=$(foreach dir, $(SOURCE_DIRS), $(patsubst $(dir)/%.erl, $(EBIN_DIR)/%.beam, $(wildcard $(dir)/*.erl)))

ERLC_OPTS=$(INCLUDE_FLAGS) $(CONTRIB_INCLUDES) $(CONTRIB_PATH) -o $(EBIN_DIR) -Wall +debug_info # +native -v

MODULES=$(shell echo $(basename $(notdir $(TARGETS))) | sed 's_ _,_g')

all: $(EBIN_DIR) $(TARGETS)

$(EBIN_DIR)/%.beam: %.erl $(INCLUDES)
	erlc $(ERLC_OPTS) $<

$(EBIN_DIR):
	mkdir -p $(EBIN_DIR)

clean:
	rm -f ebin/*.beam
	rm -f $(TARGETS)
