#!/bin/bash
set -eu

function check-success {
  touch "$RUN_LOGS/check_success"
  THIS_IMAGE=$(readlink -f $GHE_DATA_DIR/current)
  if [ "$LAST_IMAGE" = "$THIS_IMAGE" ]
  then
    RESULT='FAIL'
    RESULT_CODE='current_link_not_reset'
  else
    RESULT='SUCCESS'
    RESULT_CODE='success'
  fi
}

function write-history {
  # writes to a csv file
  # date string, target server, success/failure, backup name (current link), time taken, full or inc, incompletes, size diff
  touch "$RUN_LOGS/write_history"
  echo "$BACKUP_LABEL,$DAY_OF_WEEK,$elapsed_time,$TARGET,$RESULT,$RESULT_CODE,$THIS_IMAGE,$incremental,$backup_size,$BACKUP_VERSION,$pruning,$incompletes" >> $BACKUP_HISTORY
}

function quit {
  # if not "SUCCESS" then report failure and the output will be the error message (err_in_progress, err_incomplete
  # needs to take a success code and use that to pass along status and report
  # create output to get slacked
  touch "$RUN_LOGS/quit_function"
  END=$(date +%s)
  diff_time=$(( $END - $START ))
  elapsed_time=`date -d@$diff_time -u +%H:%M:%S`

  check-success
  size-diff backup_size
  write-history
  mv $GHE_VERBOSE_LOG $RUN_OUTPUT
  cp $LAST_IMAGE/benchmarks/* $RUN_LOGS/
  slack-message
  exit
}

function size-diff {
  local  __resultvar=$1
  touch "$RUN_LOGS/size_diff"
  mount-size final
  echo "final=$final"

  local size_diff=$(($final - $initial))
  local human_size=$(human-bytes $size_diff)
  eval $__resultvar="'$human_size'"
}


function slack-message {
  touch "$RUN_LOGS/slack_message"
  echo '```' > message.txt
  echo "$TARGET backup $THIS_IMAGE $RESULT\n" >> message.txt
  echo "Time elapsed - $elapsed_time\n" >> message.txt
  echo "Size = $backup_size\n" >> message.txt
  echo "Result code = $RESULT_CODE\n" >> message.txt
  echo '```' >> message.txt

  ./slack.sh "$TARGET Backup $RESULT" $RESULT
}

function check-in-progress {
  touch "$RUN_LOGS/check_in_progress"
echo "DEBUG in check-in-progress"
  if [ -e "$GHE_DATA_DIR/in-progress" ]
  then
    # need to write data to history, save out log, exit script, and post error to slack
    RESULT="FAIL"
    RESULT_CODE="in-progress_file_detected"
    echo "$GHE_DATA_DIR/in-progress detected" >> $GHE_VERBOSE_LOG
    quit
  fi
}

function is-incremental {
  touch "$RUN_LOGS/is_incremental"
  incremental='full'
if [ $(find $GHE_DATA_DIR -maxdepth 1 -type d | wc -l) \> 1 ]
  then
    incremental='incremental'
    # echo "true there are directories in $GHE_DATA_DIR"
  fi
}

function check-incomplete {
echo "DEBUG in check-incomplete"
  incompletes=$(find $GHE_DATA_DIR -maxdepth 2 -type f -name "incomplete" | wc -l)
}


function pruning-needed {
  touch "$RUN_LOGS/pruning_needed"
  images=$(find $GHE_DATA_DIR -maxdepth 1 -type d | wc -l)
  pruning='no'
  ((images--))
  if (( $images > $GHE_NUM_SNAPSHOTS ))
  then
  pruning='pruning'
  fi
}

function mount-size () {
  local  __resultvar=$1
  touch "$RUN_LOGS/mount_size"
  mount=$(df -P $GHE_DATA_DIR | awk 'NR==2{print $NF}')
  local mount_size=$(df $mount | grep -v 'Filesystem' | awk '{ print $3 }')
  eval $__resultvar="'$mount_size'"
}


human-bytes(){
  touch "$RUN_LOGS/human_bytes"
  B="$1"
  [ $B -lt 1024 ] && echo ${B}KB && return
  KB=$(((B+512)/1024))
  [ $KB -lt 1024 ] && echo ${KB}MB && return
  MB=$(((KB+512)/1024))
  [ $MB -lt 1024 ] && echo ${MB}GB && return
  GB=$(((MB+512)/1024))
  [ $GB -lt 1024 ] && echo ${GB}TB && return
  echo $(((GB+512)/1024))TB
}

################################################################
################################################################

<<SPEC

PRELUDE
- pre-check any incomplete flags or if current is old - /backup/git/*/incomplete
- pre-check /backup/git/in-progress
  - if in-progress, then if in-progress file is 2 days or older then report in message
- pre-detect if this is going to be a full backup and report at end if full or incremental
- pre-detect if this is going to remove an image (limit is reached)
- pre-detect size of /backup and subtract at end (if this is an incremental)
- pre-detect start time


CHECK
any errors?
  STDERR
  incomplete flag

ON COMPLETE
- check success
  - any incomplates?
  - is current link same as at start?
- move log and report log file name and location
- write entry to history

MESSAGE
- backup image name (= current softlink)
write history back to github page as a rendered .csv
SPEC


################################################################
################################################################

SCRIPT_DIR=$(dirname -- "$0")
cd $SCRIPT_DIR
source config.bk
source $BACKUP_SUITE/backup.config

# PRESET VARS FROM config.bk
#LOG_DIR='/backup/logs'
#BACKUP_SUITE='/home/ubuntu/github-backup'
#TARGET='GIT-MIG-BKP-AWS'

# INITIAL DERIVED VARS
BACKUP_VERSION=$($BACKUP_SUITE/bin/ghe-backup --version | awk '{ print $3 }')
BACKUP_HISTORY=$LOG_DIR/backup-history.txt
DAY_OF_WEEK=$(date +%a)
BACKUP_LABEL=`date '+%Y_%m_%d__%H_%M_%S'`   # create backup label = folder where logs will be kept
RUN_LOGS="$LOG_DIR/$BACKUP_LABEL"   # verbose logs dir for this backup run
RUN_OUTPUT="$RUN_LOGS/$BACKUP_LABEL.out"
LAST_IMAGE=$(readlink -f $GHE_DATA_DIR/current)
RESULT_CODE="unset"

# images - number of exsiting backup images at runtime
# pruning - image/s will be pruned as part of backup (# of backup images > GHE_NUM_SNAPSHOTS)
# incremental - this backup will be an incremantal (there are already dirs in the backup folder)

START=$(date +%s)



mkdir $RUN_LOGS   # create verbose log directory for this backup

mount-size initial
pruning-needed
check-in-progress
is-incremental
check-incomplete
/home/ubuntu/github-backup/bin/ghe-backup -v

quit
