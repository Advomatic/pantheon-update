#!/bin/bash
# pantheon-update.sh
# Bash script to run security updates on a Pantheon site.

###
# Check if Terminus is installed correctly.
###
terminus_check() {
  terminus self:info -q
  if [ $? == 0 ]; then
    echo -e "Terminus is installed!"
  else
    >&2  echo -e "${INVERSE}Either terminus is not installed, not installed globally, or is < 1.0. Please install Terminus and try again.${NOINVERSE}"
    exit 1
  fi
}

###
# Authenticate with Pantheon.
###
terminus_auth() {
  response=`terminus auth:whoami`
  if [ "$response" == "" ]; then
    echo -e "You are not authenticated with Terminus..."
    terminus auth:login
    if [ $? == 0 ]; then
      echo -e "Login successful!"
    else
      echo "${INVERSE}Login failed. Please re-run the script and try again.${NOINVERSE}"
      exit 2
    fi
  else
    echo -e "You are authenticated with Terminus as:"
    echo -e " $response"
    read -p "${UNDERLINE}[${BOLD}y${NOBOLD}]Continue or [n]login as someone else? [${BOLD}y${NOBOLD}/n]${NOUNDERLINE} " login;
    case $login in
      [Nn]) terminus auth:logout;
        terminus auth:login;;
      *) ;;
    esac
  fi
}

###
# Choose the site to update.
#
# @global $SITENAME
###
choose_site() {
  terminus site:list --fields="name,id,framework"
  read -p "${UNDERLINE}Type in site name and press [Enter] to start updating:${NOUNDERLINE} " SITENAME
}

###
# Check the framework.
#
# @global $FRAMEWORK
###
set_framework() {
  FRAMEWORK=`terminus site:info --field=framework $SITENAME`
}

###
# Create a multi-dev.
#
# @global $MDENV
###
multidev_create() {
  echo -e "Updating ${FRAMEWORK} site ${SITENAME}."
  MDENV_DEFAULT='sec'`date "+%Y%m%d"`
  read -p "${UNDERLINE}What should the multidev be called. You may use the name of an existing branch. [${BOLD}${MDENV_DEFAULT}${NOBOLD}]? ${NOUNDERLINE}"  MDENV
  MDENV="${MDENV:-$MDENV_DEFAULT}"

  # @todo Make this happen.  We'll also need to determine the framework.
  #echo -e "Pro tip:"
  #echo -e "To get to this point directly, just use arguments."
  #echo -e "  ./pantheon-update.sh ${SITENAME} ${MDENV}"
  #echo -e ""

  terminus -q env:info ${SITENAME}.${MDENV}
  if [ $? != 0 ]; then
    echo -e "Creating multidev enironment $MDENV"
    FROMENV_DEFAULT='live'
    read -p "${UNDERLINE}Use the db/files from which environment? (dev/test/${BOLD}live${NOBOLD}) ${NOUNDERLINE}"  FROMENV
    FROMENV="${FROMENV:-$FROMENV_DEFAULT}"
    echo -e "Creating multidev ${MDENV} from ${FROMENV}.  Please wait (this can take a long time)..."
    terminus -q multidev:create ${SITENAME}.${FROMENV} ${MDENV}
    if [ $? != 0 ]; then
      >&2 echo -e "Error: Could not create environment."
      exit 5;
    fi
  else
    echo -e "Multidev environment $MDENV already exists and will be used for the rest of the update."
    FROMENV_DEFAULT='none'
    read -p "${UNDERLINE}Copy db from which environment? (dev/test/live/${BOLD}none${NOBOLD}/quit)${NOUNDERLINE} " FROMENV
    FROMENV="${FROMENV:-$FROMENV_DEFAULT}"
    # @todo error check that it's not empty.
    case $FROMENV in
      quit) exit 0;;
      none) ;;
      *)
        echo -e "Copying DB from ${SITENAME}.${FROMENV} to ${MDENV}.  Please wait (this can take a long time)..."
        terminus -y -q env:clone-content ${SITENAME}.${FROMENV} ${MDENV}
        if [ $? != 0 ]; then
          cleanup_on_error "error cloning content from ${FROMENV} to ${MDENV}" 6
        fi
        ;;
    esac
  fi
}

##
# Set the connection mode for the multi-dev env.
#
# @param string $mode
#   Either "sftp" or "git"
##
multidev_connection_mode() {
  echo -e "Switching to $1 connection-mode..."
  terminus -q connection:set ${SITENAME}.${MDENV} $1
  if [ $? = 1 ]; then
    cleanup_on_error "error in switching to $1" 7
  fi
}

##
# Set the site URL.
#
# @global $MULTIDEV_URL
##
set_multidev_url() {
  MULTIDEV_URL="http://${MDENV}-${SITENAME}.pantheonsite.io/"
}

###
# Run updates.
###
multidev_update() {
  case $FRAMEWORK in
    drupal)
      drupal_set_drush_version
      drupal_check_features
      # @todo add an option to skip security updates.  i.e. Just regenerate the
      # features, and deploy
      drupal_update
      drupal_regenerate_features
      ;;
    *)
      # wordpress and drupal8
      # @link https://github.com/pixotech/Pantheon-Updates/blob/master/pantheon-update.sh#L38
      echo -e "$FRAMEWORK is not yet supported.  Do whatever it is that you do to run security updates on the multi-site, then continue."
      echo -e "  $MULTIDEV_URL"
      read -p "${UNDERLINE}Continue [${BOLD}y${NOBOLD}/n]${NOUNDERLINE} " continue;
      case $continue in
        [Nn]) cleanup_on_error "" 0 ;;
        *) ;;
      esac
      ;;
  esac
}

###
# Determine Drush version.
#
# @global $DRUSH_VERSION
###
drupal_set_drush_version() {
  echo -e "Determining the drush version."
  echo -e "${UNDERLINE}You may be asked if you wish to continue connecting.  Say yes.${NOUNDERLINE}"
  DRUSH_VERSION=`terminus drush ${SITENAME}.${MDENV} -- --version --pipe 2>/dev/null | cut -c-1`
  if [ "$DRUSH_VERSION" -lt 6 ]; then
    cleanup_on_error "The site needs to run Drush 7 for Drupal 7, Drush 8 for Drupal 8.  See https://pantheon.io/docs/drush-versions/" 12
  fi
}

###
# Check that features are not overridden.
#
# @global $HAS_FEATURES
###
drupal_check_features() {
  echo -e "Checking if Features module is installed."
  drupal_check_if_module_installed features
  if [ $? == 0 ]; then
    HAS_FEATURES=0
    return;
  fi
  HAS_FEATURES=1
  echo -e "Checking that features are not overridden."
  overridden=`terminus drush ${SITENAME}.${MDENV} features-list 2>/dev/null | fgrep Overridden`
  if [ "$overridden" != "" ]; then
    echo -e "$overridden"
    cleanup_on_error "There are features overrides.  These should be cleaned up first." 8
  fi
}

##
# List all modules that need a security update.
##
drupal_update_list_modules_needing_update() {
  echo -e "Checking which modules need an update."
  terminus drush ${SITENAME}.${MDENV} pm-updatestatus -- --security-only 2>&1 | fgrep -v '[notice]'
}

##
# Check if the given module is installed.
#
# @param string $module_name
##
drupal_check_if_module_installed() {
  installed=`terminus drush ${SITENAME}.${MDENV} pm-list -- --status=enabled --pipe 2>/dev/null | fgrep $1`
  if [ "$installed" != "" ]; then
    return 1;
  fi
}

###
# Update a Drupal site.
###
drupal_update() {

  echo -e "Checking Update Status Advanced."
  drupal_check_if_module_installed update_advanced
  if [ $? == 1 ]; then
    # @todo Either rectify this, or switch to drush locks.
    echo -e ""
    echo -e "${BOLD}This tool is not yet smart enough to understand modules locked by Update Status Advanced module."
    echo -e "${BOLD}Be sure to check this URL to see if any of the modules reported below are excluded for some reason:"
    echo -e "${BOLD}  http://live-${SITENAME}.pantheonsite.io/admin/reports/updates/settings"
    echo -e "${BOLD}Adjust those rules if necessary (maybe the most recent version needs to be ignored), and disregard the list below.  Instead use the report at:"
    echo -e "${BOLD}  http://live-${SITENAME}.pantheonsite.io/admin/reports/updates${NOBOLD}"
  fi

  terminus -q drush ${SITENAME}.${MDENV} -- rf -q
  drupal_update_list_modules_needing_update
  echo -e ""
  echo -e "${BOLD}Remember that our security update policy does not include:${NOBOLD}"
  echo -e "* Jumps to a new major version."
  echo -e "  e.g. 7.x-2.4 to 7.x-3.0"
  echo -e "* Upgrading an alpha or dev module."
  echo -e "  e.g. 7.x-1.0-alpha3 to 7.x-1.0-beta2"
  echo -e "These should be done as billable work."

  # @todo It would require less interaction if we did this a bit differently:
  #       1. Build a list of all the modules that we want to update.
  #       2. Update them one by one.  After each we ask for a commit message, as
  #          long as the user doesn't see any error messages.
  #       3. Ask the user to test the site.
  while true; do
    echo -e ""
    echo -e "${UNDERLINE}Enter one of the following:${NOUNDERLINE}"
    echo -e "* The machine-name of a module to update."
    echo -e "* 'list' to show the list again."
    echo -e "* 'none' to move on to the next step."
    read -p "? " command;
    case $command in
      none) break ;;
      list) drupal_update_list_modules_needing_update ;;
      *)
        if [ "$command" != "" ]; then
          drupal_update_module $command
          multidev_commit "Security update for $command module."
        fi
        ;;
    esac
  done;
}

##
# Update the given module to the latest stable version.
#
# @param string $module_name
##
drupal_update_module() {
  drupal_check_if_module_installed $1
  if [ $? == 0 ]; then
    echo "${INVERSE}Module $1 does not exist.${NOINVERSE}"
    return;
  fi

  echo "Updating the code for $1..."
  terminus -q drush ${SITENAME}.${MDENV} -- pm-updatecode --no-backup $1 -y
  if [ $? != 0 ]; then
    cleanup_on_error "error updating the code to the latest version." 9
  fi

  echo "Updating the database for $1..."
  terminus -q drush ${SITENAME}.${MDENV} -- updatedb -y
  if [ $? != 0 ]; then
    cleanup_on_error "error updating the database." 10
  fi

  echo -e "${BOLD}$1 has been updated. Please test it here:${NOBOLD}"
  echo -e "  $MULTIDEV_URL"
  echo -e ""
  echo -e "Some things you might need to check:"
  echo -e "* Check site functionality related to these module."
  echo -e "* Check for custom code that integrates with the updated module."
  echo -e "* Check for any patches for the module in sites/all/hacks."
  echo -e ""
  echo -e "${UNDERLINE}Continue with the process (committing the code)?${NOUNDERLINE}"
  read -p "${UNDERLINE}[${BOLD}y${NOBOLD}]es [n]o, I'll re-run the script later. [${BOLD}y${NOBOLD}/n]${NOUNDERLINE} " continue;
  case $continue in
    [Nn] ) exit 0 ;;
    *) ;;
  esac
}

##
# Commit code in the multi-dev.
#
# @param string $default_commit_message
##
multidev_commit() {
  read -p "${UNDERLINE}Please provide git commit message [${BOLD}$1${NOBOLD}]:${NOUNDERLINE} " message
  message="${message:-$1}"
  terminus -q env:commit ${SITENAME}.${MDENV} --message="$message"
  if [ $? != 0 ]; then
    cleanup_on_error "Error committing to git." 11
  fi
}

##
# Check if features need to be regenerated.
##
drupal_regenerate_features() {
  if [ "$HAS_FEATURES" == 0 ]; then
    return;
  fi
  echo -e "Clearing caches."
  terminus -q drush ${SITENAME}.${MDENV} -- cache-clear all
  echo -e "Checking if features need to be regenerated."
  overridden=`terminus drush ${SITENAME}.${MDENV} features-list 2>/dev/null | fgrep Overridden`
  if [ "$overridden" != "" ]; then
    echo -e "Regenerating these features:"
    echo -e "$overridden"
    terminus -q drush ${SITENAME}.${MDENV} -- features-update-all -y
    if [ $? != 0 ]; then
      cleanup_on_error "Error regenerating features." 12
    fi
    multidev_commit "Regenerated features."
  fi
}

##
# Merge the multi-dev to the dev site.
##
multidev_merge() {
  echo -e ""
  echo -e "${UNDERLINE}Do you wish to merge this multidev into the dev environment?${NOUNDERLINE}"
  echo -e "Some common cases where you shouldn't:"
  echo -e "* If the client should review."
  echo -e "* If deployments are always done in batches (e.g. Annenberg) and this should be included in the next batch."
  # @todo check for this.
  echo -e "* If there is undeployed code on dev (in the future, could be added to the automation)."
  read -p "${UNDERLINE}Merge?  [${BOLD}y${NOBOLD}/n]${NOUNDERLINE} " merge;
  case $merge in
    [Nn])
      echo -e "You may run this script again when you are ready to merge and deploy."
      exit 0;
      ;;
    *)
      # @todo abstract this part so that it can be run on any env., with any framework.
      echo -e "Merging ${SITENAME}.${MDENV} to dev."
      terminus -q multidev:merge-to-dev ${SITENAME}.${MDENV}
      if [ $? != 0 ]; then
        cleanup_on_error "Error merging to dev." 13
      fi
      echo -e "Clearing caches."
      terminus -q drush ${SITENAME}.dev -- cache-clear all
      echo -e "Updating the database."
      terminus -q drush ${SITENAME}.dev -- updatedb -y
      echo -e "Reverting Features."
      terminus -q drush ${SITENAME}.dev -- features-revert-all -y
      ;;
  esac
}

##
# If there was an error, ask to remove the multi-dev. Then exit.
#
# @param string $message
# @param int $return_code
##
cleanup_on_error() {
  >&2 echo -e ""
  >&2 echo -e "${INVERSE}ERROR:"
  >&2 echo -e "$1${NOINVERSE}"
  >&2 echo -e ""
  multidev_delete
  exit "$2";
}

##
# Delete the multi-dev.
#
# @param int $skip_continue_message
#  Set to 1 to skip the message about running the script again with the multidev.
##
multidev_delete() {
  if [ "$1" != 1 ]; then
    echo -e "The URL for the multidev environment is:"
    echo -e "  $MULTIDEV_URL"
    echo -e "${UNDERLINE}Delete multidev $MDENV?${NOUNDERLINE}"
    echo -e "(If you leave it you will be able to run the script again using it.)"
  else
    echo -e "${UNDERLINE}Delete multidev $MDENV?${NOUNDERLINE}"
  fi
  read -p "[${BOLD}y${NOBOLD}]es [n]o? [${BOLD}y${NOBOLD}/n] " cleanup;
  case $cleanup in
    [Nn]) ;;
    *)
      if [ "$1" != 1 ]; then
        read -p "${UNDERLINE}Delete the branch too? [y/${BOLD}n${NOBOLD}]${NOUNDERLINE} " delete_branch;
        case $delete_branch in
          [Yy]) terminus -q multidev:delete ${SITENAME}.${MDENV} --delete-branch ;;
          *) terminus -q multidev:delete ${SITENAME}.${MDENV} ;;
        esac
      else
        # Assume that we're skipping continue messages because the merge was
        # successful.  So don't even offer to delete the branch.
        terminus -q multidev:delete ${SITENAME}.${MDENV}
      fi
      ;;
  esac
}

# Used for questions and warnings.
UNDERLINE=$'\033[4m'
NOUNDERLINE=$'\033[24m'
# Used for options.
BOLD=$'\033[1m\033[36m'
NOBOLD=$'\033[97m\033[22m'
# Used for errors.
INVERSE=$'\033[7'
NOINVERSE=$'\033[27m'

terminus_check
terminus_auth
choose_site
#SITENAME=heron
set_framework
#FRAMEWORK=drupal
multidev_create
#MDENV=sec20170301
set_multidev_url
multidev_connection_mode sftp
multidev_update
#DRUSH_VERSION=7
multidev_connection_mode git
multidev_merge
multidev_delete 1
echo -e "${UNDERLINE}Sorry, the deploying and backup part hasn't been written yet. Use the Pantheon dashboard. But also run \`drush cc all\`, \`drush updb\`, and \`drush fra\`${NOUNDERLINE}"
echo -e
echo -e "Thanks.  All done."

# @todo
# Deploy to the test env. (copying DB/Files from live)
# Pause again and ask to continue.
# A full backup of production database and files
# Deploy to live.
# Show the status report
#
# @todo Ring a bell after long processes finish.
