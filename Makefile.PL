# DESCRIPTION: Perl ExtUtils: Type 'perl Makefile.PL' to create a Makefile for this package
#
# Copyright 2000-2011 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

require 5.005;
use ExtUtils::MakeMaker;
use Carp;

sub MY::postamble {
    ($ENV{RSCHLIB}
     ? "RSCHLIB = $ENV{RSCHLIB}\n"
     : "RSCHLIB = \$(PREFIX)/lib\n")
."
RSCHLIB_EDIT_FN = blib/lib/Schedule/Load/Reporter.pm

pure_all::
	\$(PERL) -p -e \"s!RSCHLIB = '.*'!RSCHLIB = '\$(RSCHLIB)'!g\" < \$(RSCHLIB_EDIT_FN) > \$(RSCHLIB_EDIT_FN).new
	mv -f \$(RSCHLIB_EDIT_FN).new \$(RSCHLIB_EDIT_FN)

install::
	-mkdir -p    \$(RSCHLIB)/rschedule
	-chmod a+rwx \$(RSCHLIB)/rschedule

install-here::
	make	RSCHLIB=/import/nauticus/common/lib \\
		install

install-test::
	make	INSTALLMAN1DIR=/usr/local/man/man1 INSTALLMAN3DIR=/usr/local/man/man3 \\
		INSTALLBIN=/usr/local/test/bin 	INSTALLSCRIPT=/usr/local/test/bin \\
		INSTALLSITELIB=/usr/local/test/lib \\
		INSTALLSITEARCH=/usr/local/test/lib/i686-linux \\
		RSCHLIB=/usr/local/test/lib \\
		install

README: readme.texi
	-\$(RM_RF) \$@
	makeinfo \$< --output \$@ --no-headers --no-validate

## Maintainer use:
preexist:
	svnorcvs nexists \$(DISTNAME)_\$(VERSION_SYM)
	test -s README

tag:
	svnorcvs tag  \$(DISTNAME)_\$(VERSION_SYM)

maintainer-diff:
	svnorcvs diff \$(DISTNAME)_\$(VERSION_SYM)

maintainer-dist: preexist dist tag
	svnorcvs release \$(DISTVNAME).tar.gz

maintainer-clean: distclean
	-\$(RM_RF) README Makefile

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
	      NO_META	=> 1,
	      PREREQ_PM => {'IPC::Locker' => 1.410,	# IPC::PidStat, enclosed within
			    'Filesys::DfPortable' => 0,
			    'Proc::ProcessTable' => 0.40,
			    'Pod::Usage' => 1.34,
			    'Storable' => 0,
			    'Time::HiRes' => 0,
			    'Unix::Processors' => 2.020,
			},
	      EXE_FILES	=> [qw( rschedule slchoosed slchoosed_watchd slreportd slpolice slrsh)],
	      'clean'	=> {FILES => 'test_store', },
	      'dist'	=> {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz',
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

