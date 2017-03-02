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
    >&2  echo -e "Either terminus is not installed, not installed globally, or is < 1.0. Please install Terminus and try again."
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
      echo "Login failed. Please re-run the script and try again."
			exit 2
		fi
	else
		echo -e "You are authenticated with Terminus as:"
		echo -e " $response"
		read -p "[y]Continue or [n]login as someone else? [y/n] " login;
		case $login in
			[Yy]* ) ;;
			[Nn]* ) terminus auth:logout;
        terminus auth:login;;
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
  read -p 'Type in site name and press [Enter] to start updating: ' SITENAME
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
	echo "Updating ${FRAMEWORK} site ${SITENAME}."
	MDENV='sec'`date "+%Y%m%d"`

  terminus -q env:info ${SITENAME}.${MDENV}
	if [ $? != 0 ]; then
		echo -e "Creating multidev enironment $MDENV"
		read -p "Use the db/files from which environment (probably live)? (dev/test/live) "	FROMENV
		echo -e "Creating multidev ${MDENV} from ${FROMENV}.  Please wait..."
		terminus multidev:create ${SITENAME}.${FROMENV} ${MDENV}
		if [ $? != 0 ]; then
			>&2 echo -e "error in creating env."
      exit 5;
		fi
	else
    echo -e "Multidev environment $MDENV already exists and will be used for the rest of the update."
    # @todo Add an option for assuming that the update is already complete on the multidev, and just deploy.
    read -p "Copy  db from which environment (probably none)? (dev/test/live/none/abort) " FROMENV
    case $FROMENV in
      abort) exit 0;;
      none) ;;
      *)
        echo -e "Copying DB from ${SITENAME}.${FROMENV} to ${MDENV}.  Please wait..."
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
# @global $SITE_URL
##
set_site_url() {
  SITE_URL="http://${MDENV}-${SITENAME}.pantheonsite.io/"
}

###
# Run updates.
###
multidev_update() {
  case $FRAMEWORK in
    drupal)
      drupal_set_drush_version
      drupal_check_features
      drupal_update
      ;;
    *)
      # wordpress and drupal8
      # @link https://github.com/pixotech/Pantheon-Updates/blob/master/pantheon-update.sh#L38
      echo -e "$FRAMEWORK is not yet supported.  Do whatever it is that you do to run security updates on the multi-site, then continue."
      echo -e "  $SITE_URL"
      read -p "Continue [y/n] " continue;
      case $continue in
        [Yy]* ) ;;
        [Nn]* ) cleanup_on_error "" 0 ;;
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
  echo -e "You may be asked if you wish to continue connecting.  Say yes."
  DRUSH_VERSION=`terminus drush ${SITENAME}.${MDENV} -- --version --pipe 2>/dev/null | cut -c-1`
  if [ "$DRUSH_VERSION" -lt 6 ]; then
    cleanup_on_error "The site needs to run at least drush version 6 (7 preferred).  See https://pantheon.io/docs/drush-versions/" 12
  fi
}

###
# Check that features are not overridden.
###
drupal_check_features() {
  echo -e "Checking that features are not overridden."
  overridden=`terminus drush ${SITENAME}.${MDENV} features-list 2>/dev/null | fgrep Overridden`
  if [ "$overridden" != "" ]; then
    echo -e "$overridden"
    cleanup_on_error "There are features overrides.  These should be cleaned up first with \`terminus drush ${SITENAME}.${MDENV} features-list\`." 8
  fi
}

###
# Update a Drupal site.
###
drupal_update() {

  echo -e "Updating the code with drush."
  terminus -q drush ${SITENAME}.${MDENV} -- rf -q

  # @todo Needs to understand modules ignored by update-advanced.
  # @todo for drush > 5 we should first run update-status, then ask the user which module to update, iterate until they choose to stop.
	terminus -q drush ${SITENAME}.${MDENV} -- pm-update --security-only --no-core=1 --check-updatedb=0 --no-backup
	if [ $? != 0 ]; then
    cleanup_on_error "error updating the code to the latest version." 9
	fi

  echo "Running 'drush updb'..."
  terminus -q drush ${SITENAME}.${MDENV} -- updatedb -y
  if [ $? != 0 ]; then
    cleanup_on_error "error updating the database." 10
  fi

  echo -e "Site's modules have been updated. Please test it here:"
  echo -e "  $SITE_URL"
  echo -e ""
  echo -e "Some things you might need to check:"
  echo -e "* Check site functionality related to these module(s)."
  echo -e "* Check for custom code that integrates with the updated module(s)."
  echo -e "* Check for any patches for the module(s) in sites/all/hacks."
  # @todo Add a step for this.
  echo -e "* Run \`terminus drush ${SITENAME}.${MDENV} -- features-diff\` to see if any features need to be rebuilt."
  echo -e ""
  echo -e "Continue with the process?"
  read -p "[y]es [n]o, I'll re-run the script later. [y/n] " continue;
  case $continue in
    [Yy]* ) ;;
    [Nn]* ) exit 0 ;;
  esac

  multidev_commit
}

##
# Commit code in the multi-dev.
##
multidev_commit() {
  read -p "Please provide git commit message: " message
  terminus env:commit ${SITENAME}.${MDENV} --message="$message"
  if [ $? != 0 ]; then
    cleanup_on_error "Error committing to git." 11
  fi
}

##
# If there was an error, ask to remove the multi-dev. Then exit.
#
# @param string $message
# @param int $return_code
##
cleanup_on_error() {
  >&2 echo -e "$1"
  delete_multidev
  exit "$2";
}

##
# Delete the multi-dev.
##
delete_multidev() {
	echo -e "The URL for the multidev environment is:"
  echo -e "  $SITE_URL"
  echo -e "Delete multidev $MDENV? (If you leave it you will be able to run the script again using it.)"
  read -p "[y]es [n]o? [y/n] " cleanup;
  case $cleanup in
    [Yy]* ) 
      read -p "Delete the branch too? [y]es [n]o? [y/n] " delete_branch;
      case $delete_branch in
        [Yy]* ) terminus multidev:delete ${SITENAME}.${MDENV} --delete-branch ;;
        [Nn]* ) terminus multidev:delete ${SITENAME}.${MDENV} ;;
      esac
    [Nn]* ) ;;
  esac
}

terminus_check
terminus_auth
choose_site
#SITENAME=heron
set_framework
#FRAMEWORK=drupal
multidev_create
#MDENV=sec20170301
set_site_url
multidev_connection_mode sftp
multidev_update
#DRUSH_VERSION=5
multidev_connection_mode git
cleanup_on_error "Sorry, the rest hasn't been written yet." 0

# @todo
# Asks you whether you want to deploy, or abort. It should give some pointers of some common cases where you should abort:
#
#     If the client should client review.
#     If deployments are always done in batches (e.g. Annenberg) and this should be included in the next batch.
#     If there is undeployed code on dev (in the future, could be added to the automation)
#
# If you choose to continue, It commits the updates in Git and merges into master. If an error, bail.
# Delete the multi-dev env.
# Deploy to the test env. (copying DB/Files from live)
# Pause again and ask to continue.
# A full backup of production database and files
# Deploy to live.
