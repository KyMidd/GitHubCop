#/bin/bash

# Global vars
GH_ORG=your-org-name

# Auth requirements
if [ -z "$GITHUB_TOKEN" ]; then
  echo "GITHUB_TOKEN not set, exiting"
  exit 0
fi


###
### Functions
###

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
    if (( "$API_RATE_LIMIT_UNITS_REMAINING" < 100 )); then
      echo "ℹ️  We have less than 100 GitHub API rate-limit tokens left, sleeping for 1 minute"
      sleep 60
    
    # If API rate-limiting shows remaining units, break out of loop and exit function
    else  
      break
    fi

  done
}


###
### Static information
### 

# Security product features to enable for all repos
# Ref: https://docs.github.com/en/rest/orgs/orgs?apiVersion=2022-11-28#enable-or-disable-a-security-feature-for-an-organization
REPO_SECURITY_FEATURES_TO_ENABLE=(
    advanced_security # Will fail if licensing for all repos is not available. All repos with GHAS remain enabled, new repos are not enabled until licensing is present
    secret_scanning
    secret_scanning_push_protection
    dependency_graph
    dependabot_alerts
    dependabot_security_updates
    code_scanning_default_setup # Should be last because it's quite slow to enable
)


###
### Write what's happening
###
echo "########################################"
echo "🚀 Setting Org-Wide Repo Security Features"
echo "########################################"


###
### Hold until rate-limiting is not hit
###
hold_until_rate_limit_success


###
### Set some org-level permissions
###

for SECURITY_FEATURE in "${REPO_SECURITY_FEATURES_TO_ENABLE[@]}"; do
    
    ###
    ### Print into info
    ###
    echo ""
    echo "########################################"
    echo "🚀 Attempting to enable $SECURITY_FEATURE for all repos"
    echo "########################################"


    ###
    ### Hold until rate-limiting is not hit
    ###
    hold_until_rate_limit_success


    # Since each of these can fail if executed too fast, enter a while loop
    # Break out of the while loop when the command succeeds
    while true; do
        # Clean
        rm -rf http.response.code
        rm -rf curl.output
        
        # Enable security feature for all repos
        # Capture http response code and curl output, write to file
        curl -s \
            --write-out "%{http_code}" \
            --output curl.output \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN"\
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/orgs/$GH_ORG/$SECURITY_FEATURE/enable_all \
            1> http.response.code

        CURL_RESPONSE_CODE=$(cat http.response.code)
        CURL_OUTPUT=$(cat curl.output)
        
        # If we get error about "security product toggling", we are executing too fast, wait 10 seconds and try again
        if [[ $(echo "$CURL_OUTPUT" | jq -r '.errors' | grep -E 'Security product toggling is in progress' || true) ]]; then
            echo "⏳ Waiting for previous security feature to complete, retrying in 10 seconds..."
            sleep 10
        
        # If we get an http 204 back, all went well. If not, print error and continue
        elif [[ $CURL_RESPONSE_CODE -ne 204 ]]; then
            echo "☠️  Something went wrong enabling $SECURITY_FEATURE for all repos, error message:"
            echo "$(echo $CURL_OUTPUT | jq -r '.errors')"
            
            # Uncaught errors mean we won't retry
            break
        
        # If we got a 204 response and no error output, we are good to go
        else
            echo "✅ Successfully requested $SECURITY_FEATURE to be enabled for all repos for $GH_ORG Org"
            
            # Success means we won't retry
            break
        fi
    done
done

# Finish strong
echo ""
echo "###################"
echo "Run complete!"
echo "###################"

exit 0