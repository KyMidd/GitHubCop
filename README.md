# GitHubCop

This repo and automation in it are designed to set all GitHub repo permissions required for a new repo. 

To use it, update the "repo_info.csv" file with any new repos with a PR. When the PR is merged, the github action will read this file and update permissions on each repo in sequence, top to bottom. 

# Repo settings that are updated

##### Delete branch on merge
##### Actions Settings
- Enable Actions permissions to Allow enterprise, and select non-enterprise...
##### Update collaborator permissions
- Add DevOps as admin on repo
- Add team (collection)Leads as Admin on repo (Optional, if value blank in CSV this action will be skipped)
- Add CI as admin permissions on repo
##### Add branch protection against develop and master
- Each might not exist
- Require a PR before merging
- Require xx approvals (Optional, defaults to 1, can specify 1-6 inclusive)
- Dismiss stale pull requests when new commits are pushed
- Require status checks to pass before merging
- Require branches be up to date before merging
- Status check required: "jenkins_pr_validate_any" (Optional, defaults to true. Set CSV value to false to skip)
- Status check required: "Git_Commit_Checker"
- Require conversation resolution before merging
- Restrict who can push to matching branches
- Uncheck "do not allow bypassing the above settings"
- Check "allow specific actors to bypass required pull requests" with user automation-ci

# Permission Collisions

This script sets specific settings directly. If there are direct colissions, this app will update them to what it shows. If a repo has a setting that is getting over-written and shouldn't be, remove it from the repo_info.csv file, and it will no longer be updated in future when this automation runs. 

# Triggers

The automation will run when the PR is merged or can be run manually on the github web console. 

