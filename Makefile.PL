# $Id: Makefile.PL,v 1.13 2001/11/15 14:18:39 wsnyder Exp $
# DESCRIPTION: Perl ExtUtils: Type 'perl Makefile.PL' to create a Makefile for this package

require 5.005;
use ExtUtils::MakeMaker;
use Carp;

sub MY::postamble {
"
install::
	-mkdir -p /usr/local/lib/rschedule
	-chmod a+rw /usr/local/lib/rschedule

install-here::
	make INSTALLMAN1DIR=/usr/local/man/man1 INSTALLMAN3DIR=/usr/local/man/man3 INSTALLBIN=/usr/local/bin INSTALLSCRIPT=/usr/local/bin install

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

dist: distcheck
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
			    'Unix::Processors' => 0,  #1.6, but no VERSION there
			    'Storable' => 0,
			    'Time::HiRes' => 0,
			},
	      EXE_FILES	=> [qw( rschedule slchoosed slreportd slpolice slrsh)],
	      'clean'	=> {FILES => 'test_store', },
	      'dist'	=> {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz', 
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

