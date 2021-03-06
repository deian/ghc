# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------


# Here's an interesting rule!

# The .hi file may or may not change when we compile the corresponding
# .hs file.  If GHC figures out that the .hi file has not changed, it
# doesn't touch it.  This is a useful optimisation, because it means
# some modules may not get recompiled if the .hi files of the modules
# they depend on have not changed.
#
# See:
#   http://hackage.haskell.org/trac/ghc/wiki/Commentary/Compiler/RecompilationAvoidance
#
# So how do we express this dependency to make?  The exact form of
# this rule is quite fragile.  Here are some versions that don't work
# very well:
#
# %.hi : %.o
# 	@if [ ! -f $@ ] ; then \
# 	    echo Panic! $< exists, but $@ does not.; \
# 	    exit 1; \
# 	fi
#
# This version adds a useful sanity check; but it is also expensive on
# Windows where spawning a shell takes a while (about 0.3s).  We'd
# like to avoid the shell if necessary.  This also hides the message
# "nothing to be done for 'all'", since make thinks it has actually done
# something.
#
# %.hi : %.o
#
# This version doesn't work: GNU make knows it has't done anything to
# update the .hi file, so even if the .o file has been updated, it
# won't rebuild anything that depends on the .hi file.  So you might
# think a more correct way is to change the .hs rule:
#
# %.hi %.o : %.hs
#	$(HC) ...
#
# this says "compiling %.hs updates both %.hi and %.o", but that's not
# true, since compiling the .hs file might not update the .hi file, if
# the .hi file didn't change.  And if we use this version, then make
# will keep trying to rebuild %.hi if it is out of date with respect
# to %.hs.
#
# Using this form seems to be the best compromise:
#
# %.hi : %.o ;
#
# the ';' at the end signifies an "empty command" (see the GNU make
# documentation).  An empty command is enough to get GNU make to think
# it has updated %.hi, but without actually spawning a shell to do so.

define hi-rule # $1 = way

%.$$($1_hisuf) : %.$$($1_osuf) ;

%.$$($1_way_)hi-boot : %.$$($1_way_)o-boot ;

endef

