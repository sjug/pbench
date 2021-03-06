#! /bin/bash

# Usage: pbench-verify-backup-tarballs

# Method: in each directory, concatenate all the .md5 files and
# pass them to md5sum for verification (eliminate DUPLICATEs for now: they
# are handled incorrectly by pbench-{move,copy}-results and that needs to
# be fixed).

# For each directory, select all the files that don't pass the md5 check
# and report them. TBD: Report also whether the two sets match between directories
# (IOW, if they were corrupted to begin with).

# Then compare the rest: there might be a few more files in the primary dir
# than in the backup dir, if any additional tarballs have been sent and the
# backup has not dealt with them yet. That is reported but it's only temporary
# so it's OK.

# Any other discrepancy is flagged and reported.

# The second argument is specific to this script: it's the backup
# directory.  The first and the (optional) third arg are consumed by
# pbench-base.sh.  This is the same convention that is used by
# pbench-backup-tarballs.

# load common things
. $dir/pbench-base.sh

test -d $ARCHIVE || doexit "Bad archive: $ARCHIVE"
primary=$ARCHIVE

backup=$(getconf.py pbench-backup-dir pbench-server)
test ! -z $backup || doexit "Unspecified backup directory, no pbench-backup-dir config in pbench-server section"
test -d $backup || doexit "Bad backup directory: $backup"

# work files
controllers=$TMP/$PROG/controllers.$$
files=$TMP/$PROG/files.$$
allmd5s=$TMP/$PROG/allmd5s.$$
list=$TMP/$PROG/list.$$
out=$TMP/$PROG/out.$$
only=$TMP/$PROG/only.$$
report=$TMP/$PROG/report.$$
index_content=$TMP/$PROG/index_mail_contents

# make sure the directory exists
mkdir -p $TMP/$PROG || doexit "Failed to create $TMP/$PROG"

trap "rm -f $controllers.[pb] $files.[pb] $allmd5s.[pb] $list.[pb] $out.[pb] $list.[pb].failed $only.[pb] $report $index_content; rmdir $TMP/$PROG" EXIT INT QUIT

# First argument is the exit code to use when a directory does not exist.
function checkmd5 {
    find . -maxdepth 1 -type d | grep -v '^\.$' | sort > $controllers.$1
    while read d ;do
        pushd $d > /dev/null 2>&4 || exit $2
        ls | grep md5 | grep -v DUPLICATE__NAME > $files.$1
        > $allmd5s.$1
        while read f ;do
            if [ -s $f ]; then
                cat $f >> $allmd5s.$1
            else
                echo "FAIL: Empty .md5 file: $d/$f"
            fi
        done < $files.$1
        if [ -s $allmd5s.$1 ] ;then
            cat $allmd5s.$1 | sed -r 's;(^[0-9a-f]+)  (.+);\1  '$d/'\2;' >> $list.$1
            md5sum --check --warn $allmd5s.$1 | sed 's;^;'$d/';'
        fi
        popd > /dev/null 2>&4
    done < $controllers.$1
}

log_init $PROG

echo "start-$(timestamp)"

# Initialize index mail content
> $index_content

# primary archive
> $out.p
if cd $primary ;then
    checkmd5 p 5 > $out.p 2>&1 &
fi

# backup location
> $out.b
if cd $backup ;then
    checkmd5 b 6 > $out.b 2>&1 &
fi

wait

let ret=0

# Construct the report file
> $report

grep -E "(^md5sum: |FAIL)" $out.p > $list.p.failed
if [ -s $list.p.failed ] ;then
    (echo "* In $primary: the calculated MD5 of the following entries failed to match the stored MD5"
     cat $list.p.failed | sed 's;^\.;'$primary';'; echo) >> $report
elif [ -s $out.p -a ! -s $list.p.failed ] ;then
    :
else
    echo "Primary list is empty - is $primary mounted?" >> $report
    ret=7
fi

grep -E "(^md5sum: |FAIL)" $out.b > $list.b.failed
if [ -s $list.b.failed ] ;then
    (echo "* In $backup: the calculated MD5 of the following entries failed to match the stored MD5"
     cat $list.b.failed | sed 's;^\.;'$backup';'; echo) >> $report
elif [ -s $out.b -a ! -s $list.b.failed ] ;then
    :
else
    echo "Backup list is empty - is $backup mounted?" >> $report
    ret=8
fi

# TBD: compare the two lists of FAILED files and report appropriately.

# Check for discrepancies but only if both files are non-empty: if for whatever reason,
# one of the mount points is not available, we will get the underlying directory which
# will be empty.

if [[ $ret == 0 ]] ;then
    comm -23 --nocheck-order $list.p $list.b > $only.p
    comm -13 --nocheck-order $list.p $list.b > $only.b

    if [ -s $only.p ] ;then
        (echo "* Files that exist only in primary directory - extra files in this list are probably OK: they just have not been backed up yet.";
         cat $only.p | sed 's;^\.;'$primary';') >> $report
    fi

    if [ -s $only.b ] ;then
        (echo "* Files that exist only in backup directory - this should only happen if a backup or primary tar ball becomes corrupted.";
         cat $only.b | sed 's;^\.;'$backup';') >> $report
    fi
fi

echo "end-$(timestamp)"

log_finish

# send it
subj="$PROG.$TS($PBENCH_ENV)"
cat << EOF > $index_content
$subj
EOF

cat $report >> $index_content
pbench-report-status --name $PROG --timestamp $TS --type status $index_content

exit $ret
