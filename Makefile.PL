# $Id: Makefile.PL,v 1.19 2004/01/27 19:03:50 wsnyder Exp $
# DESCRIPTION: Perl ExtUtils: Type 'perl Makefile.PL' to create a Makefile for this package
#
# Copyright 2000-2004 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

require 5.005;
use ExtUtils::MakeMaker;
use Carp;

sub MY::postamble {
"

RSCHLIB = /usr/local/lib
RSCHLIB_EDIT_FN = blib/lib/Schedule/Load/Reporter.pm

pure_all::
	\$(PERL) -p -e \"s!RSCHLIB = '.*'!RSCHLIB = '\$(RSCHLIB)'!g\" < \$(RSCHLIB_EDIT_FN) > \$(RSCHLIB_EDIT_FN).new
	mv \$(RSCHLIB_EDIT_FN).new \$(RSCHLIB_EDIT_FN)

install::
	-mkdir -p   \$(RSCHLIB)/rschedule
	-chmod a+rw \$(RSCHLIB)/rschedule

install-here::
	make	INSTALLMAN1DIR=/usr/local/man/man1 INSTALLMAN3DIR=/usr/local/man/man3 \
		INSTALLBIN=/usr/local/bin INSTALLSCRIPT=/usr/local/bin \
		RSCHLIB=/usr/local/lib \
		install

install-test::
	make	INSTALLMAN1DIR=/usr/local/man/man1 INSTALLMAN3DIR=/usr/local/man/man3 \
		INSTALLBIN=/usr/local/test/bin 	INSTALLSCRIPT=/usr/local/test/bin \
		INSTALLSITELIB=/usr/local/test/lib \
		INSTALLSITEARCH=/usr/local/test/lib/i686-linux \
		RSCHLIB=/usr/local/test/lib \
		install

README: readme.texi
	-rm \$@
	makeinfo \$< --output \$@ --no-headers --no-validate

## Maintainer use:
tag:
	cvs tag -F \$(DISTNAME)_\$(VERSION_SYM) .

maintainer-dist: dist tag
	cp \$(DISTVNAME).tar.gz \$(HOME)/src/kits
	mv \$(DISTVNAME).tar.gz \$(HOME)/backpack

maintainer-clean: distclean
	-rm README Makefile

dist: distcheck README
";
}

## Remember to upgrade version number!
WriteMakefile(
	      DISTNAME	=> 'Schedule-Load',
	      NAME	=> 'Schedule::Load',
	      AUTHOR	=> 'Wilson Snyder <wsnyder@wsnyder.org>',
	      ABSTRACT_FROM => 'Load.pm',
	      VERSION_FROM  => 'Load.pm',
	      PREREQ_PM => {'Proc::ProcessTable' => 0,
			    'Unix::Processors' => 1.7,
			    'Storable' => 0,
			    'Time::HiRes' => 0,
			    'IPC::PidStat' => 1.410,
			},
	      EXE_FILES	=> [qw( rschedule slchoosed slreportd slpolice slrsh)],
	      'clean'	=> {FILES => 'test_store', },
	      'dist'	=> {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz', 
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

