#!/bin/sh

# Run this script to set up the Werc environment on OpenBSD.
# Werc's website: http://werc.cat-v.org/

# ---- variables ----

# This section contains customizable variables, consider setting their values
# before running the script.

# The domain of your server.
# An invalid domain may result in an unsuccessful or incomplete installation.
domain='example.com'

# The root directory for httpd's chroot environment.
# The default value is usually fine and it should not be changed unless the
# change is backed by a valid reason. If unsure, do not change.
webdir='/var/www'

# ---- end variables ----

# ---- functions ----

# check if a directory (or one of the parents of that directory) is an fstab entry marked as "nodev"
# directories marked as "nodev" cannot contain special devices (e.g. /dev/null)
is_nodev() {
	dir="$1"

	fstab_dir=`fstab_parent $dir`

	if echo $fstab_dir | grep -E ',?nodev,?' >/dev/null
	then
		return 0
	fi

	return 1
}

# extract the directory from an /etc/fstab entry which contains a directory or one of its parents
fstab_parent() {
	dir="$1"

	for entry in `awk '{ print $2 }' </etc/fstab`
	do
		echo $dir | grep -E "^$entry(/|$)" >/dev/null
		test $? -eq 0 && return 0
	done

	return 1
}

# acts like ln if possible, otherwise cp
lncp() {
	ln "$@" 2>/dev/null || cp "$@"
}

# ---- end functions ----

# exit on first error
set -o errexit

# check os
test "$(uname)" != "OpenBSD" && { echo "$0: operating system is not OpenBSD" >&2 ; exit 1 ; }

# check root
test "$(whoami)" != "root" && { echo "$0: not running as root" >&2 ; exit 1 ; }

# default values if unset or empty
domain=${domain:-"example.com"}
webdir=${webdir:-"/var/www"}

# check webdir's value
echo "$webdir" | grep -E '^(/[^[:cntrl:]]+)+$' >/dev/null
if [ $? -eq 1 ]
then
	echo "$0: invalid chroot directory" >&2
	exit 1
fi

pkg_add bzip2 plan9port
p9pdir='/usr/local/plan9'

ftp -S dont http://code.9front.org/hg/werc/archive/tip.tar.bz2
tar xjf tip.tar.bz2 -C $webdir
rm tip.tar.bz2
mv $webdir/werc-* $webdir/werc

siteroot="$webdir/werc/sites/$domain"
mkdir $siteroot
cp -r $siteroot/../default.cat-v.org/_werc $siteroot
cp -r $webdir/werc/lib $siteroot/_werc
printf "# congratulations\n\nit works! :)\n" >$siteroot/index.md

# backup current httpd.conf
if [ -r /etc/httpd.conf ]
then
	cp /etc/httpd.conf /etc/httpd.conf.bk
	echo "$0: /etc/httpd.conf already exists, it has been copied to /etc/httpd.conf.bk" >&2
fi

# new httpd.conf
# for some reason, httpd waits until timeout ("connection request timeout") for some files
echo \
'server "'$domain'" {

	# see https://man.openbsd.org/httpd.conf to enable ssl/tls

	listen on * port 80
	connection request timeout 4

	location "/pub/*" {
		root "/werc"
	}

	location found "/*" {
		root "/werc/sites/'$domain'"
	}

	location not found "/*" {
		root "/"
		fastcgi {
			param PLAN9 "'$p9pdir'"
			param DOCUMENT_ROOT "/werc/bin"
			param SCRIPT_FILENAME "/werc/bin/werc.rc"
			socket "/run/slowcgi.sock"
		}
	}
}

types {
	include "/usr/share/misc/mime.types"
}
' >/etc/httpd.conf

if is_nodev $webdir
then
	cp /etc/fstab /etc/fstab.bk

	# remove "nodev" from $webdir in /etc/fstab so that we can create /dev/null
	# this requires a reboot to be effective
	oldline=$(grep `fstab_parent $webdir` </etc/fstab)
	newline=`echo "$oldline" | sed 's/nodev//' | sed 's/,,/,/'`
	oldfile=`cat /etc/fstab`
	echo "$oldfile" | sed "s!$oldline!$newline!" >/etc/fstab
	echo "$0: /etc/fstab has been changed, a reboot is required at the end of the setup process"
fi

# create devices in $webdir
mkdir -p "$webdir/dev"
p=$(pwd)
cd $webdir/dev
/dev/MAKEDEV std
cd $p

# create /tmp in $webdir
mkdir -p "$webdir/tmp"
chmod 1777 "$webdir/tmp"

# lncp required things into the chroot environment
mkdir -p $webdir$p9pdir $webdir/usr/libexec $webdir/usr/lib $webdir/bin $webdir$p9pdir/lib
lncp $p9pdir/rcmain $webdir$p9pdir
lncp /usr/libexec/ld.so $webdir/usr/libexec
lncp /usr/lib/lib{m,util,pthread,c,z,expat}.so* $webdir/usr/lib
lncp /bin/{pwd,mv} $webdir/bin
lncp $p9pdir/lib/fortunes $webdir$p9pdir/lib

# recursively lncp everyting (including sub-dirs) under $p9pdir/bin into the chroot environment
allbins="$(find $p9pdir/bin -not -type d | sed "s|^$p9pdir/bin/||")"
for bin in $allbins
do
	dir=$(dirname $bin)
	mkdir -p $webdir/bin/$dir
	lncp $p9pdir/bin/$bin $webdir/bin/$bin
done

# enable slowcgi and httpd
rcctl enable slowcgi httpd

echo "$0: setup completed!"
echo "$0: check prior messages to see if you need to reboot; otherwise, you can start the httpd and slowcgi services"

exit 0
