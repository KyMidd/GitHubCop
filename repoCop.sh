#!/bin/bash

# If CSV file doesn't have trailing return, last value will be skipped. Add it to be safe.
echo "" >> repo_info.csv

# Global vars
GH_ORG=your-org-name

# Unset all_repos, mostly useful for local testing re-runs
unset ALL_REPOS

# Auth requirements
if [ -z "$GITHUB_TOKEN" ]; then
  echo "GITHUB_TOKEN not set, exiting"
  exit 0
fi


###
### Declare functions
###

# Can define a variable using a heredoc
define() { 
  IFS=$'\n' read -r -d '' ${1} || true; 
}

# Grant permissions to repo
rest_grant_repo_permissions() {
	# Map named variables to local vars
	for ARGUMENT in "$@"; do
		KEY=$(echo $ARGUMENT | cut -f1 -d=)

		KEY_LENGTH=${#KEY}
		VALUE="${ARGUMENT:$KEY_LENGTH+1}"

		export "$KEY"="$VALUE"
	done

    # Normalize team slugs to convert periods and ampersands to dashes to match github behavior
    TEAM_SLUG=$(echo $TEAM_SLUG | sed 's/\./-/g'| sed 's/\&/-/g')

    unset CURL
    CURL=$(curl -s \
    -X PUT \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    https://api.github.com/orgs/$GH_ORG/teams/$TEAM_SLUG/repos/$GH_ORG/$GH_REPO \
    -d "{\"permission\":\"$PERMISSION\"}" 2>&1)
    if [[ $(echo "$CURL" | grep -E "Problems|Not Found") ]]; then
        echo "☠️ Something bad happened granting $TEAM_SLUG access to the repo, please investigate response:"
        echo "$CURL"
    else
        echo "💥 Successfully granted $TEAM_SLUG $PERMISSION access to repo $GH_REPO"
    fi
}

# Set branch protection using REST
branch_protections_rest() {

	# Map named variables to local vars
	for ARGUMENT in "$@"; do
		KEY=$(echo $ARGUMENT | cut -f1 -d=)

		KEY_LENGTH=${#KEY}
		VALUE="${ARGUMENT:$KEY_LENGTH+1}"

		export "$KEY"="$VALUE"
	done

	# Make work with variables
	if [ "$JENKINS_ANY_JOB_ENABLE" = true ]; then
		# Any_ Job enabled, require it
		define requiredStatusCheckContexts @- <<-EOF
			{
				"context":"Git_Commit_Checker"
			},
			{
				"context":"jenkins_pr_validate_any"
			}
		EOF
	else
		# Any_ job not enabled, don't require it
		define requiredStatusCheckContexts <<-EOF
			{
				"context":"Git_Commit_Checker"
			}
		EOF
	fi

	# Post request
	CURL=$(curl -s \
	-X PUT \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: Bearer $GITHUB_TOKEN" \
	https://api.github.com/repos/$GH_ORG/$GH_REPO/branches/$BRANCH/protection \
	-d @- <<- EOF
	{
		"required_status_checks":{
			"strict":false,
			"checks":[$requiredStatusCheckContexts]
			},
			"restrictions":{
				"users":[],
				"teams":[],
				"apps":[]
			},
			"required_signatures":false,
			"required_pull_request_reviews":{
				"dismiss_stale_reviews":true,
				"require_code_owner_reviews":true,
				"required_approving_review_count":$REQUIRED_APPROVERS_COUNT,
				"require_last_push_approval":true,
				"bypass_pull_request_allowances":{
					"users":[
						"automation-ci"
					],
					"teams":[],
					"apps":[]
				}
			},
			"enforce_admins":false,
			"required_linear_history":false,
			"allow_force_pushes":false,
			"allow_deletions":false,
			"block_creations":false,
			"required_conversation_resolution":true,
			"lock_branch":false,
			"allow_fork_syncing":false
	}
	EOF
	)
	
	if [[ $(echo "$CURL" | grep -E "Problems|not found") ]]; then
		echo "☠️ Something bad happened setting branch protections on $BRANCH, please investigate response:"
		echo "$CURL"
	else
		echo "💥 Successfully set branch protections on $BRANCH"
	fi
}

# Lookup branch protection rule, delete it, graphql, useful for rules containing a wildcard
delete_branch_protection_rule_graphql() {

	# Map named variables to local vars
	for ARGUMENT in "$@"; do
		KEY=$(echo $ARGUMENT | cut -f1 -d=)

		KEY_LENGTH=${#KEY}
		VALUE="${ARGUMENT:$KEY_LENGTH+1}"

		export "$KEY"="$VALUE"
	done

	# Fetch the repo node_id for use with graphql
    REPO_NODE_ID=$(curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN"\
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/repos/$GH_ORG/$GH_REPO | jq -r '.node_id')

    if [[ "$REPO_NODE_ID" == "null" ]]; then
        echo "☠️ Something bad happened fetching the repo node_id, please investigate response:"
        echo "$REPO_NODE_ID"
        return 0
    fi

    # Check if the release/* branch protection exists. If yes, store the ID of the rule
    BRANCH_PROTECTION_RULES=$(curl -s \
        -X POST \
        -H "Authorization: bearer $GITHUB_TOKEN" \
        https://api.github.com/graphql \
        -d @- <<- EOF
        { 
			"query": "query {
				repository (
					owner: \"$GH_ORG\",
					name: \"$GH_REPO\"
				) {
					branchProtectionRules(first:5) {
						nodes {
							id,
							pattern
						}
					}
				}
            }"
        }
		EOF
	)
	
	BRANCH_PROTECTION_ID=$(echo "$BRANCH_PROTECTION_RULES" | jq -r ".data.repository.branchProtectionRules.nodes[] | select(.pattern==\"$BRANCH_PROTECTION_PATTERN\") | .id")

    # Delete the branch protection rule if it exists
    DELETE_BRANCH_PROTECTION_RULE=$(curl -s \
        -X POST \
        -H "Authorization: bearer $GITHUB_TOKEN" \
        -H 'Content-Type: application/graphql' 2>&1 \
        https://api.github.com/graphql \
        -d @- <<- EOF
		{
			"query": "mutation {
				deleteBranchProtectionRule(
					input: {
						branchProtectionRuleId: \"$BRANCH_PROTECTION_ID\"
					}
				) {
					clientMutationId
				}
			}"
		}
		EOF
	)
}

# Set branch protections using graphql, required for branches with / or * characters
branch_protections_graphql() {

	# Map named variables to local vars
	for ARGUMENT in "$@"; do
		KEY=$(echo $ARGUMENT | cut -f1 -d=)

		KEY_LENGTH=${#KEY}
		VALUE="${ARGUMENT:$KEY_LENGTH+1}"

		export "$KEY"="$VALUE"
	done

	JENKINS_ANY_JOB_ENABLE=$JENKINS_ANY_JOB_ENABLE
	BRANCH=$BRANCH

	# Delete branch protection rule
	delete_branch_protection_rule_graphql BRANCH_PROTECTION_PATTERN='release/*'

	if [ "$JENKINS_ANY_JOB_ENABLE" = true ]; then
		# Any_ Job enabled, require it
		define requiredStatusCheckContexts @- <<-EOF
		requiredStatusCheckContexts: [
			\"Git_Commit_Checker\",
			\"jenkins_pr_validate_any\"
		]
		EOF
	else
		# Any_ job not enabled, don't require it
		define requiredStatusCheckContexts <<-EOF
		requiredStatusCheckContexts: [
			\"Git_Commit_Checker\"
		]
		EOF
	fi

	unset CURL
    CURL=$(curl -s \
        -X POST \
        -H "Authorization: bearer $GITHUB_TOKEN" \
        -H 'Content-Type: application/graphql' \
        https://api.github.com/graphql 2>&1 \
        -d @- <<- EOF
        {
            "query": "mutation {
                createBranchProtectionRule(
                    input: {
                        repositoryId: \"$REPO_NODE_ID\",
                        pattern: \"$BRANCH\",
                        allowsDeletions: true,
                        requiresStatusChecks: true,
                        $requiredStatusCheckContexts,
                        bypassPullRequestActorIds: [
                            \"$AUTOMATION_CI_USER_NODE_ID\"
                        ],
                        restrictsPushes: true, 
                        requiresStrictStatusChecks: false, 
                        dismissesStaleReviews: true, 
                        requiresCodeOwnerReviews: true, 
                        requiredApprovingReviewCount: $REQUIRED_APPROVERS_COUNT, 
                        requireLastPushApproval: true, 
                        requiresCommitSignatures: false, 
                        lockAllowsFetchAndMerge: false, 
                        blocksCreations: false, 
                        allowsForcePushes: false, 
                        isAdminEnforced: false, 
                        requiresLinearHistory: false, 
                        lockBranch: false, 
                        requiresConversationResolution: true, 
                        requiresApprovingReviews: true, 
                    } 
                ) 
                { 
                    branchProtectionRule { 
                        pattern 
                    } 
                } 
            }"
        }
		EOF
		)

    if [[ $(echo "$CURL" | grep -E "Name already protected") ]]; then
        echo "☠️ Unable to remove the previous branch protections using graphql, please investigate response:"
        echo "$CURL"
    elif [[ $(echo "$CURL" | grep -E "Problems|Not Found|Parse error|NOT_FOUND") ]]; then
        echo "☠️ Something bad happened setting branch protections on $BRANCH, please investigate response:"
        echo "$CURL"
    else
        echo "💥 Successfully set branch protections on $BRANCH"
    fi
}

# Get branches for a repo, write to a file
get_repo_branches() {

	# Cleanup last
	unset ALL_BRANCHES
	
	# This amazingly hacky way to get a repo count appears to be the only way, no official support in the APIs
	# https://stackoverflow.com/a/33252219/12072110
	REPO_BRANCH_COUNT=$(curl -vvvs \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer $GITHUB_TOKEN"\
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"https://api.github.com/repos/$GH_ORG/$GH_REPO/branches?per_page=1" 2>&1 1>/dev/null | grep -E '< link: <https://' | rev | cut -d ">" -f 2 | cut -d "=" -f1 | rev)
	
	# If this attribute is missing, there is only one page, which means 1 repo
    if [[ $( echo "$REPO_BRANCH_COUNT" | awk 'NF' | wc -l) -eq 0 ]]; then
        REPO_BRANCH_COUNT=1
    fi
    
    # Less than or equal to 100 branches, get them all in one request
    if [[ $REPO_BRANCH_COUNT -le 100 ]]; then
        ALL_BRANCHES=$(curl -sL \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            https://api.github.com/repos/$GH_ORG/$GH_REPO/branches?per_page=100 | jq -r '.[].name')

    # More than 100 branches, get them in multiple requests
    else

        # Calculate number of pages needed to get all repos
        BRANCHES_PER_PAGE=100
        PAGES_NEEDED=$(($REPO_BRANCH_COUNT / $BRANCHES_PER_PAGE))
        if [ $(($REPO_BRANCH_COUNT % $BRANCHES_PER_PAGE)) -gt 0 ]; then
            PAGES_NEEDED=$(($PAGES_NEEDED + 1))
        fi

        # Get all branches
        for PAGE_NUMBER in $(seq $PAGES_NEEDED); do
            #echo "Getting branches page $PAGE_NUMBER of $PAGES_NEEDED"
            
            PAGINATED_BRANCHES=$(curl -sL \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $GITHUB_TOKEN"\
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/$GH_ORG/$GH_REPO/branches?per_page=$BRANCHES_PER_PAGE&page=$PAGE_NUMBER" | jq -r '.[].name')
            
            # Combine all pages of repos into one variable
            # Extra return added since last item in list doesn't have newline (would otherwise combine two repos on one line)
            ALL_BRANCHES="${ALL_BRANCHES}"$'\n'"${PAGINATED_BRANCHES}"
        done

        # Remove any empty lines
        ALL_BRANCHES=$(echo "$ALL_BRANCHES" | awk 'NF')

        # Copy to file
        #echo "$ALL_BRANCHES" > repo_branches
    fi
}

# Create an auto-link reference for a repository
create_repo_autolink_reference() {

  # Map first argument to ticket key
  TICKET_REF=$1

  # If no ticket key provided, skip
  if [ -z "$TICKET_REF" ]; then
    echo "☠️ No ticket key provided, skipping"
    return 0
  fi

  # Create an auto-link reference 
  CREATE_AUTOLINK_REF=$(curl -sL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN"\
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$GH_ORG/$GH_REPO/autolinks \
    -d "{\"key_prefix\":\"${TICKET_REF}-\",\"url_template\":\"https://veradigm.atlassian.net/browse/${TICKET_REF}-<num>\",\"is_alphanumeric\":false}")

  # If the auto-link reference already exists, skip
  if [[ $(echo "$CREATE_AUTOLINK_REF" | jq -r '.errors[]?.code' | grep -E 'already_exists') ]]; then
    #echo "☠️ Auto-link reference already exists for $TICKET_REF, skipping"
    CREATE_AUTOLINK_REFERENCE_ALREADY_EXIST+=($TICKET_REF)
  
  # If created successfully, return success
  elif [[ $(echo "$CREATE_AUTOLINK_REF" | jq -r '.key_prefix') == "${TICKET_REF}-" ]]; then
    #echo "💥 Successfully created auto-link reference for $TICKET_REF"
    CREATE_AUTOLINK_REFERENCE_SUCCESSES+=($TICKET_REF)

  # If something else happened, return detailed failure message
  else
    echo "☠️ Something bad happened creating auto-link reference for $TICKET_REF, please investigate response:"
    echo "$CREATE_AUTOLINK_REF"
    CREATE_AUTOLINK_REFERENCE_FAILURES+=($TICKET_REF)
  fi
}

# Create auto-link references for all projects
create_repo_autolink_references() {
  
  # Get existing auto-link references, if any
  EXISTING_AUTOLINK_REFERENCES=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN"\
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$GH_ORG/$GH_REPO/autolinks | jq -r '.[]?.key_prefix' | cut -d '-' -f 1 | awk 'NF')

  # Set array of project keys to build for this project
  AUTOLINK_REFERENCES_TO_BUILD=$(echo "$AUTOLINK_JIRA_PROJECT_KEYS" | tr ' ' '\n')
  
  # If there are existing auto-link references, remove them from the list of auto-link references to build
  if [[ $(echo "$EXISTING_AUTOLINK_REFERENCES" | awk 'NF' | wc -l) -gt 0 ]]; then
    while IFS=$'\n' read -r EXISTING_AUTOLINK_REFERENCE; do
      AUTOLINK_REFERENCES_TO_BUILD=$(echo "$AUTOLINK_REFERENCES_TO_BUILD" | grep -v "$EXISTING_AUTOLINK_REFERENCE")
    done <<< "$EXISTING_AUTOLINK_REFERENCES"
  fi
  
  # Create array to store success/failures
  CREATE_AUTOLINK_REFERENCE_SUCCESSES=()
  CREATE_AUTOLINK_REFERENCE_ALREADY_EXIST=()
  CREATE_AUTOLINK_REFERENCE_FAILURES=()

  # Count length of project keys to build and project key total to build
  AUTOLINK_REFERENCES_TO_BUILD_LENGTH=$(echo "$AUTOLINK_REFERENCES_TO_BUILD" | awk 'NF' | wc -l | xargs)
  AUTOLINK_JIRA_PROJECT_KEYS_LENGTH=$(echo "$AUTOLINK_JIRA_PROJECT_KEYS" | awk 'NF' | wc -l | xargs)

  # If any auto-link references to build, loop through them, create as we go
  if [[ $(echo "$AUTOLINK_REFERENCES_TO_BUILD" | awk 'NF' | wc -l | xargs) -gt 0 ]]; then
    while IFS=$'\n' read -r PROJECT_KEY; do
      create_repo_autolink_reference "$PROJECT_KEY"
    done <<< "${AUTOLINK_REFERENCES_TO_BUILD[@]}"
  fi
  
  # Create counts vars
  CREATE_AUTOLINK_REFERENCE_SUCCESSES_LENGTH=${#CREATE_AUTOLINK_REFERENCE_SUCCESSES[@]}
  CREATE_AUTOLINK_REFERENCE_ALREADY_EXISTS_LENGTH=${#CREATE_AUTOLINK_REFERENCE_ALREADY_EXIST[@]}
  CREATE_AUTOLINK_REFERENCE_FAILURES_LENGTH=${#CREATE_AUTOLINK_REFERENCE_FAILURES[@]}

  # If AUTOLINK_REFERENCES_TO_BUILD_LENGTH is 0, then all auto-link references already exist
  if [[ $AUTOLINK_REFERENCES_TO_BUILD_LENGTH -eq 0 ]]; then
    echo "ℹ️  All $AUTOLINK_JIRA_PROJECT_KEYS_LENGTH Jira auto-link references already exist, skipping"
  
  # If there are failures, print error message
  elif [[ $CREATE_AUTOLINK_REFERENCE_FAILURES_LENGTH -gt 0 ]]; then
    echo "ℹ️  $CREATE_AUTOLINK_REFERENCE_SUCCESSES_LENGTH/$AUTOLINK_REFERENCES_TO_BUILD_LENGTH auto-link references created, but some failures ($CREATE_AUTOLINK_REFERENCE_FAILURES_LENGTH/$AUTOLINK_JIRA_PROJECT_KEYS_LENGTH), please investigate"
  
  # If there are no failures, print success message
  else
    echo "💥 Successfully created $CREATE_AUTOLINK_REFERENCE_SUCCESSES_LENGTH auto-link reference for all $AUTOLINK_JIRA_PROJECT_KEYS_LENGTH configured Jira project keys"
  fi
}

# Check if hitting API rate-limiting
hold_until_rate_limit_success() {
  
  # Loop forever
  while true; do
    
    # Any call to AWS returns rate limits in the response headers
    API_RATE_LIMIT_UNITS_REMAINING=$(curl -sv \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/$GH_ORG/$GH_REPO/autolinks 2>&1 1>/dev/null \
      | grep -E '< x-ratelimit-remaining' \
      | cut -d ' ' -f 3 \
      | xargs \
      | tr -d '\r')

    # If API rate-limiting is hit, sleep for 1 minute
    # Rounded parenthesis are used to trigger arithmetic expansion, which compares more than the first numeric digit (bash is weird)
    if (( "$API_RATE_LIMIT_UNITS_REMAINING" < 100 )); then
      echo "ℹ️  We have less than 100 GitHub API rate-limit tokens left, sleeping for 1 minute"
      sleep 60
    
    # If API rate-limiting shows remaining units, break out of loop and function
    else  
      echo "ℹ️  Rate limit checked, we have "$API_RATE_LIMIT_UNITS_REMAINING" core tokens remaining so we are continuing"
      break
    fi

  done
}

# Read the shard file and split ALL_REPOS file based on it
shard_all_repos() {
  # Read the list of repos into a var
  ALL_REPOS=$(cat all_repos)

  # Count lines in the list of repos
  ALL_REPOS_LENGTH=$(echo "$ALL_REPOS" | awk 'NF' | wc -l | xargs)
  
  # Shard number
  SHARD_NUMBER=$(echo "$SHARD" | cut -d "/" -f 1)

  # Number of shards
  SHARD_COUNT=$(echo "$SHARD" | cut -d "/" -f 2)

  # If repo length is 1, and we are not primary builder (SHARD_NUMBER=1), skip. No need for multiple builders for 1 repo
  if [[ $ALL_REPOS_LENGTH -eq 1 ]] && [[ $SHARD_NUMBER -ne 1 ]]; then
    echo "ℹ️  Only 1 repo, and not primary builder, exiting"
    exit 0
  fi

  # If only 1 repo, and primary builder, math
  if [[ $ALL_REPOS_LENGTH -eq 1 ]]; then
    # There's only 1 repo, so we can't shard it, so we'll just use 1 line per shard
    LINES_PER_SHARD=1

  # If more than 1 repo, regular slightly fuzzy math
  else

    # Number of lines per shard, add 1 to round up fractional shards
    # Lines aren't duplicated, last shard is slightly short of even with others, which is fine
    LINES_PER_SHARD=$((ALL_REPOS_LENGTH / SHARD_COUNT))
    LINES_PER_SHARD=$((LINES_PER_SHARD + 1))

  fi

  # Shard the list based on the shard fraction
  # This outputs files like all_repos_00, all_repos_01, all_repos_02, etc
  split -l $LINES_PER_SHARD -d all_repos all_repos_

  # Select shard to work - minus one since `split` starts counting at 0
  SHARD_TO_WORK_ON=$(($SHARD_NUMBER - 1))

  # Read in the ALL_REPOS variable based on created shard file
  ALL_REPOS=$(cat all_repos_0${SHARD_TO_WORK_ON})

  # Count the repos
  ALL_REPOS_COUNT=$(echo "$ALL_REPOS" | awk 'NF' | wc -l | xargs)

  # Print info
  if [[ $ALL_REPOS_LENGTH -gt 1 ]]; then
    echo "ℹ️  There are $ALL_REPOS_LENGTH repos, and we are sharding work into $SHARD_COUNT shards, so each shard will have around $LINES_PER_SHARD repos (Note: fuzzy math)"
  fi

}


###
### Hold any actions until we confirm not rate-limited
###
hold_until_rate_limit_success


###
### Read the matrix'd shard file and split ALL_REPOS file based on it
###
shard_all_repos


###
### Static info
###

# Automation-CI User Node-ID
AUTOMATION_CI_USER_NODE_ID=$(curl -s \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: Bearer $GITHUB_TOKEN"\
	-H "X-GitHub-Api-Version: 2022-11-28" \
	https://api.github.com/users/automation-ci | jq -r '.node_id')

# Define the projects to create autolink references for
AUTOLINK_JIRA_PROJECT_KEYS=(
  AM
  APO
  APOPS
  ART
  ASTRA
  BNR
  BOP
  BUS
  CAN
  CLP
  DAT
  DLT
  DMD
  DO
  DSP
  EDU
  ELT
  FAC
  FEAP
  FORT
  HYD
  LSA
  MKT
  NOP
  PAC
  PB
  PD
  PHI
  PHR
  PRD
  REL
  RES
  SAN
  SEC
  SIN
  SMH
  SOP
  SRE
  TECH
  TEST
  TSD
  UX
  WAT
)
AUTOLINK_JIRA_PROJECT_KEYS=$(echo "${AUTOLINK_JIRA_PROJECT_KEYS[@]}" | tr ' ' '\n')


###
### Iterate over all repos and set settings, branch protections, permissions, etc.
###

echo ""
echo "########################################"
echo Iterating through $ALL_REPOS_COUNT repos
echo "########################################"

# Initialize counter var to keep track of repo processing
CURRENT_REPO_COUNT=1

# Iterate over all repos
while IFS=$'\n' read -r GH_REPO; do

    ###
    ### Check if GH_REPO var blank. If yes, continue to next loop
    ###
    if [[ $GH_REPO == "" ]]; then
      continue
    fi
    
    ###
    ### Start new loop
    ###
    echo ""
    echo "⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️ ⚙️"

    
    ###
    ### Check if hitting API rate-limiting. If yes, sleep for 1 minute and check again
    ### Currently loops forever until rate-limiting is not hit
    ###
    hold_until_rate_limit_success
    
    
    ###
    ### Print repo info
    ###
    echo "➡️  ("$CURRENT_REPO_COUNT"/"$ALL_REPOS_COUNT") Inspecting $GH_ORG/$GH_REPO"

    
    ###
    ### Increment counter variable
    ###
    ((CURRENT_REPO_COUNT++))


    ###
    ### Test if repo exists. If not, skip to next repo
    ### 
    CURL=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN"\
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$GH_ORG/$GH_REPO)
    if [[ $(echo "$CURL" | grep -E "Not Found") ]]; then
        echo "☠️ Repo $GH_ORG/$GH_REPO does not exist, skipping"
        # Continue to next item in while loop, skip rest of settings here
        continue
    fi


    ###
    ### Exclude any repos in excluded_repos.csv file
    ### These repos are special snowflakes, and excluded from automated policies
    ###
    while IFS="," read -r excluded_repo
    do
        # Normalize casing to lowercase to avoid case match miss
        excluded_repo_lowercase=$(echo $excluded_repo | tr '[A-Z]' '[a-z]')
        gh_repo_lowercase=$(echo "$GH_REPO" | tr '[A-Z]' '[a-z]')

        if [[ "$gh_repo_lowercase" = "$excluded_repo_lowercase" ]]; then
            echo "Repo $GH_REPO is on the excluded list and will be skipped"
            # "continue 2" skips this while loop and also the enclosing one, skipping the repo from any action
            continue 2
        fi
    done < excluded_repos.csv


    ###
    ### Read the repo_info.csv file and modify any variables that are different from the defaults
    ###

    # Create all CSV fields for smuggling data out of while loop
    echo "" > COLLECTION_NAME
    echo "" > REQUIRED_APPROVERS_COUNT
    echo "" > JENKINS_ANY_JOB_ENABLE
    
    # Set initial vars to files since substring variable setting doesn't affect parent process
    echo "1" > REQUIRED_APPROVERS_COUNT
    echo "false" > JENKINS_ANY_JOB_ENABLE
    REQUIRED_APPROVERS_COUNT=$(cat REQUIRED_APPROVERS_COUNT)
    JENKINS_ANY_JOB_ENABLE=$(cat JENKINS_ANY_JOB_ENABLE)

    # Set canary var for if CSV finds match
    CSV_MATCH_FOUND=false
    echo "false" > CSV_MATCH_FOUND
    
    # Loop over every repo in CSV. If repo present, read values to over-ride defaults
    while IFS="," read -r GH_REPO_CSV COLLECTION_NAME REQUIRED_APPROVERS_COUNT JENKINS_ANY_JOB_ENABLE
    do
        # Ignore the headers line of the CSV
        if [[ $GH_REPO_CSV == "GH_REPO" ]]; then
            continue
        fi

        # Ignore comment lines in the CSV
        if [[ $GH_ORG =~ ^\# ]]; then
            continue
        fi

        # Ignore any blank lines in CSV
        if [[ -z $GH_ORG ]]; then
            continue
        fi

        # Normalize casing to lowercase to avoid case match miss
        GH_REPO_CSV_LOWERCASE=$(echo $GH_REPO_CSV | tr '[A-Z]' '[a-z]')
        gh_repo_lowercase=$(echo $GH_REPO | tr '[A-Z]' '[a-z]')

        # If current repo matches CSV repo, read values to over-ride defaults
        if [[ "$gh_repo_lowercase" = "$GH_REPO_CSV_LOWERCASE" ]]; then

            # Print if we've found match
            echo "ℹ️  Repo CSV match found, using those values to modify default policy"

            # If collection name is blank, skip those permissions
            if [ ! -z "$COLLECTION_NAME" ]; then
                COLLECTION_SLUG=$(echo $COLLECTION_NAME | tr '[A-Z]' '[a-z]')
                echo "ℹ️  Collection name is \"$COLLECTION_NAME\" and slug is \"$COLLECTION_SLUG\""
                # Write var
                echo $COLLECTION_NAME > COLLECTION_NAME
            else
                echo "ℹ️  Collection name not specified, skipping those permissions"
            fi

            # If approvers count populated in var, set var
            if [ ! -z "$REQUIRED_APPROVERS_COUNT" ]; then
                echo $REQUIRED_APPROVERS_COUNT > REQUIRED_APPROVERS_COUNT
            fi

            # If jenkins any job enable populated in CSV, set var
            if [ ! -z "$JENKINS_ANY_JOB_ENABLE" ]; then
                echo $JENKINS_ANY_JOB_ENABLE > JENKINS_ANY_JOB_ENABLE
            fi

            # Set canary var that CSV modifications happened
            echo "true" > CSV_MATCH_FOUND
            
            # When find CSV match, stop searching
            break
        fi

    done < repo_info.csv

    # Read Vars from CSV over-rides
    COLLECTION_NAME=$(cat COLLECTION_NAME)
    REQUIRED_APPROVERS_COUNT=$(cat REQUIRED_APPROVERS_COUNT)
    JENKINS_ANY_JOB_ENABLE=$(cat JENKINS_ANY_JOB_ENABLE)
    CSV_MATCH_FOUND=$(cat CSV_MATCH_FOUND)

    # If no CSV match found for repo name, applying default values only
    if [[ "$CSV_MATCH_FOUND" = false ]]; then
        echo "ℹ️  No CSV over-ride match found, applying default repo values"
    fi


    ###
    ### Construct collection team names
    ### If collection name is blank, skip those permissions
    ###
    
    if [ ! -z "$COLLECTION_NAME" ]; then
        COLLECTION_SLUG=$(echo $COLLECTION_NAME | tr '[A-Z]' '[a-z]')

        # Construct team names
        SERVICES_LEADS_TEAM_NAME="$COLLECTION_NAME"ServicesLeads
        TEST_LEADS_TEAM_NAME="$COLLECTION_NAME"TestLeads
        UI_LEADS_TEAM_NAME="$COLLECTION_NAME"UiLeads
        DATA_LEADS_TEAM_NAME="$COLLECTION_NAME"DataLeads

        # Construct github team slugs
        SERVICES_LEADS_TEAM_SLUG=$(echo $SERVICES_LEADS_TEAM_NAME | tr '[A-Z]' '[a-z]')
        TEST_LEADS_TEAM_SLUG=$(echo $TEST_LEADS_TEAM_NAME | tr '[A-Z]' '[a-z]')
        UI_LEADS_TEAM_SLUG=$(echo $UI_LEADS_TEAM_NAME | tr '[A-Z]' '[a-z]')
        DATA_LEADS_TEAM_SLUG=$(echo $DATA_LEADS_TEAM_NAME | tr '[A-Z]' '[a-z]')
    fi


    ###
    ### If private, set to internal
    ###
    unset CURL
    CURL=$(curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN"\
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/repos/$GH_ORG/$GH_REPO 2>&1 | jq -r '.visibility')
    if [[ "$CURL" = "private" ]]; then
        # Repo visibility set to Private, updating to Internal
        unset CURL
        CURL=$(curl -s \
            -X PATCH \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN"\
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/$GH_ORG/$GH_REPO \
            -d '{"visibility":"internal"}' 2>&1 | jq -r '.visibility')
        if [[ $(echo "$CURL") -eq "internal" ]]; then
            echo "💥 Successfully set Private repo to Internal"
        else
            echo "Something went wrong setting the repo to internal, please investigate"
            echo "$CURL"
        fi
    fi

    # Print out info
    echo "ℹ️  Setting required approvers count to: $REQUIRED_APPROVERS_COUNT"


    ###
    ### Enable github actions on repo
    ###
    unset CURL
    CURL=$(curl -s \
      -X PUT \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      https://api.github.com/repos/$GH_ORG/$GH_REPO/actions/permissions \
      -d @- <<- EOF
        {
          "enabled":true,
          "allowed_actions":"selected"
        }
			EOF
    )
    if [[ $(echo "$CURL" | wc -l) -le 1 ]]; then
        echo "💥 Successfully set Actions enabled"
    else
        echo "☠️ Something bad happened setting actions enable, please investigate response:"
        echo "$CURL"
    fi


    ###
    ### Set repo policies
    ###
    unset CURL
    CURL=$(curl -s \
      -X PATCH \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      https://api.github.com/repos/$GH_ORG/$GH_REPO 2>&1 \
      -d @- <<- EOF
        {
          "delete_branch_on_merge":true,
          "allow_squash_merge":true
        }
			EOF
	  )
    # Check for errors
    if [[ $(echo "$CURL" | grep -E 'Not Found|exceed seat allowance') ]]; then
      echo "☠️ Something bad happened setting repo policies, please investigate response:"
      echo "$CURL"
    else
      echo "💥 Successfully set repo to delete branch on merge"
      echo "💥 Successfully set repo to enable squash merge"
      echo "💥 Successfully set automatically delete head branches"
    fi


    ###
    ### Grant static permissions, same for every repo
    ###

    # Grant infosec team read access
    rest_grant_repo_permissions TEAM_SLUG='infosec' PERMISSION='read'

    # Grant DevOps team admin access
    rest_grant_repo_permissions TEAM_SLUG='devops' PERMISSION='admin'

    
    # Grant CI user write access
    rest_grant_repo_permissions TEAM_SLUG='ci' PERMISSION='admin'

    # Grant engineering team push (read/write) access
    rest_grant_repo_permissions TEAM_SLUG='engineering' PERMISSION='push'

    ###
    ### Grant dynamic permissions, based on repo name and/or collection name
    ###

    # If the repo's collection is populated, assign those permissions
    if [ ! -z "$COLLECTION_NAME" ]; then
      # Normalize capitalization of collection name into slug
      COLLECTION_SLUG=$(echo $COLLECTION_NAME | tr '[A-Z]' '[a-z]')
      GH_REPO_LOWERCASE=$(echo $GH_REPO | tr '[A-Z]' '[a-z]')
      
      # If Collection name is UI, grant UI team admin, granting merge rights
      if [[ "$COLLECTION_SLUG" == "ui" ]]; then
        echo "ℹ️  Repo classified as UI"
        # Admins
        rest_grant_repo_permissions TEAM_SLUG='uileads' PERMISSION='admin'
        # There are no other *Leads groups for UI collection
              
      # If data repo, promote data leads to admin, granting merge rights
      elif [[ "$GH_REPO_LOWERCASE" == *"database"* ]]; then
        echo "ℹ️  Repo classified as Database"
        # Admins
        rest_grant_repo_permissions TEAM_SLUG=$DATA_LEADS_TEAM_SLUG PERMISSION='admin'
        rest_grant_repo_permissions TEAM_SLUG='dataarchitect' PERMISSION='admin'
        # Maintain
        rest_grant_repo_permissions TEAM_SLUG=$SERVICES_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$TEST_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$UI_LEADS_TEAM_SLUG PERMISSION='push'
      
      # If test repo, promote test to admin, granting merge rights
      elif [[ "$GH_REPO_LOWERCASE" == *"test"* ]]; then 
        echo "ℹ️  Repo classified as Test"   
        #Admins
        rest_grant_repo_permissions TEAM_SLUG=$TEST_LEADS_TEAM_SLUG PERMISSION='admin'
        # Maintain
        rest_grant_repo_permissions TEAM_SLUG=$SERVICES_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$UI_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$DATA_LEADS_TEAM_SLUG PERMISSION='push'
      
      # If collection name doesn't match others, classify as Platform
      else
        echo "ℹ️  Repo classified as Services (default classification)"
        # Admins
        rest_grant_repo_permissions TEAM_SLUG=$SERVICES_LEADS_TEAM_SLUG PERMISSION='admin'
        # Maintain
        rest_grant_repo_permissions TEAM_SLUG=$TEST_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$UI_LEADS_TEAM_SLUG PERMISSION='push'
        rest_grant_repo_permissions TEAM_SLUG=$DATA_LEADS_TEAM_SLUG PERMISSION='push'
      fi
    fi


    ###
    ### Get branches, set protection on exigent ones
    ###

    # Get repo branches, write to file
    get_repo_branches
    
    # If branch exists, protect it
    if [[ $(echo "$ALL_BRANCHES" | grep -E "^master$") ]]; then
      branch_protections_rest BRANCH='master'
    fi
    if [[ $(echo "$ALL_BRANCHES" | grep -E "^develop$") ]]; then
      branch_protections_rest BRANCH='develop'
    fi
    if [[ $(echo "$ALL_BRANCHES" | grep -E "^main$") ]]; then
      branch_protections_rest BRANCH='main'
    fi


    ###
    ### Set static protection for release/* wildcard branch rule
    ###

    # Protect release/* branch
    branch_protections_graphql \
        JENKINS_ANY_JOB_ENABLE=$JENKINS_ANY_JOB_ENABLE \
        BRANCH='release/*'


    ###
    ### Create Repo AutoLink References
    ###

    # Create repo autolink references to connect ticket strings to Jira tickets via hyperlinks
    create_repo_autolink_references

done <<< "$ALL_REPOS"

echo "###################"
echo "Run complete!"
echo "###################"

exit 0
