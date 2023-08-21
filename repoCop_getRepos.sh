#!/bin/bash

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

# Get org repos, store in ALL_REPOS var
get_org_repos() {

  ###
  ### Now that we have more than 1k repos, need to use paginated REST call to get all of them (search API hard limit of 1k)
  ###

  # Grab Org info to get repo counts
  curl -sL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN"\
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/orgs/$GH_ORG > org_info.json

  # Filter org info to get repo counts
  PRIVATE_REPO_COUNT=$(cat org_info.json | jq -r '.owned_private_repos')
  PUBLIC_REPO_COUNT=$(cat org_info.json | jq -r '.public_repos')
  TOTAL_REPO_COUNT=$(($PRIVATE_REPO_COUNT + $PUBLIC_REPO_COUNT))

  # Calculate number of pages needed to get all repos
  REPOS_PER_PAGE=100
  PAGES_NEEDED=$(($TOTAL_REPO_COUNT / $REPOS_PER_PAGE))
  if [ $(($TOTAL_REPO_COUNT % $REPOS_PER_PAGE)) -gt 0 ]; then
      PAGES_NEEDED=$(($PAGES_NEEDED + 1))
  fi

  # Get all repos
  for PAGE_NUMBER in $(seq $PAGES_NEEDED); do
      echo "Getting repos page $PAGE_NUMBER of $PAGES_NEEDED"
      
      # Could replace this with graphql call (would likely be faster, more efficient), but this works for now
      PAGINATED_REPOS=$(curl -sL \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $GITHUB_TOKEN"\
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/orgs/$GH_ORG/repos?per_page=$REPOS_PER_PAGE&sort=pushed&page=$PAGE_NUMBER" | jq -r '.[].name')
      
      # Combine all pages of repos into one variable
      # Extra return added since last item in list doesn't have newline (would otherwise combine two repos on one line)
      ALL_REPOS="${ALL_REPOS}"$'\n'"${PAGINATED_REPOS}"
  done

  # Find archived repos
  ARCHIVED_REPOS=$(gh repo list $GH_ORG -L 1000 --archived | cut -d "/" -f 2 | cut -f 1)
  ARCHIVED_REPOS_COUNT=$(echo "$ARCHIVED_REPOS" | wc -l | xargs)

  # Remove archived repos from ALL_REPOS
  echo "Skipping $ARCHIVED_REPOS_COUNT archived repos, they are read only"
  for repo in $ARCHIVED_REPOS; do
    ALL_REPOS=$(echo "$ALL_REPOS" | grep -Ev "^$repo$")
  done

  # Remove any empty lines
  ALL_REPOS=$(echo "$ALL_REPOS" | awk 'NF')

  # Get repo count
  ALL_REPOS_COUNT=$(echo "$ALL_REPOS" | wc -l | xargs)

  # Prepend failing repo name at top to test failure conditions
  #ALL_REPOS=$(echo "$ALL_REPOS" | sed '1s/^/intentionally-missing-repo-name\n/')
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
    if [[ "$API_RATE_LIMIT_UNITS_REMAINING" < 100 ]]; then
      echo "ℹ️  We have less than 100 GitHub API rate-limit tokens left, sleeping for 1 minute"
      sleep 60
    
    # If API rate-limiting shows remaining units, break out of loop and exit function
    else  
      echo ℹ️  Rate limit checked, we have "$API_RATE_LIMIT_UNITS_REMAINING" core tokens remaining so we are continuing
      break
    fi

  done
}


###
### Hold any actions until we confirm not rate-limited
###
hold_until_rate_limit_success


###
### Get Org-wide info
###

echo "########################################"
echo Getting All Org Repos
echo "########################################"

get_org_repos

# Write Org repos to file
echo "$ALL_REPOS" > all_repos