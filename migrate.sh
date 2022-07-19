#!/bin/bash
set -euo pipefail

SOURCE_GITLAB=${SOURCE_GITLAB:=git.mycpompany.de}
TARGET_GITLAB=${TARGET_GITLAB:=gitlab.com}
if [ -z ${SOURCE_PATH+x} ]; then
	printf "Enter source group path at ${SOURCE_GITLAB} (e.g. project/team): "
	read -r SOURCE_PATH
fi
if [ -z ${TARGET_PATH+x} ]; then
	printf "Enter target group path at ${TARGET_GITLAB} (e.g. mycompany/project/team): "
	read -r TARGET_PATH
fi
if [ -z ${ARCHIVE_AFTER_MIGRATION+x} ]; then
	printf "Archive original projects at ${SOURCE_GITLAB} after migration? (yes/no): "
	read -r ARCHIVE_AFTER_MIGRATION
fi
if [ -z ${ADD_DESCRIPTION+x} ]; then
	printf "Add description to original projects at ${SOURCE_GITLAB} after migration? (yes/no): "
	read -r ADD_DESCRIPTION
fi
if [ -z ${MIGRATE_ARCHIVED_PROJECTS+x} ]; then
	printf "Migrate archived projects? (yes/no): "
	read -r MIGRATE_ARCHIVED_PROJECTS
fi
if [ -z ${MIGRATE_GROUP_VARIABLES+x} ]; then
	printf "Migrate group variables? (yes/no): "
	read -r MIGRATE_GROUP_VARIABLES
fi
if [ -z ${MIGRATE_PROJECT_VARIABLES+x} ]; then
	printf "Migrate project variables? (yes/no): "
	read -r MIGRATE_PROJECT_VARIABLES
fi
if [ -z ${MIGRATE_BADGES+x} ]; then
	printf "Migrate badges? (yes/no): "
	read -r MIGRATE_BADGES
fi
if [ -z ${MIGRATE_HOOKS+x} ]; then
	printf "Migrate hooks? (yes/no): "
	read -r MIGRATE_HOOKS
fi
#SOURCE_PATH=""
#TARGET_PATH=""
#ARCHIVE_AFTER_MIGRATION="no"
#ADD_DESCRIPTION="no"
#MIGRATE_ARCHIVED_PROJECTS="no"
#MIGRATE_GROUP_VARIABLES="no"
#MIGRATE_PROJECT_VARIABLES="no"
#MIGRATE_BADGES="no"
#MIGRATE_HOOKS="no"
CURL_PARAMS="--raw"

# only read from .secrets if env vars not existing
if [ -z ${SOURCE_ACCESS_TOKEN+x} ] || [ -z ${TARGET_ACCESS_TOKEN+x} ]; then
  echo "Reset GitLab access tokens, attempting to read from .secrets file"
  unset -v SOURCE_ACCESS_TOKEN TARGET_ACCESS_TOKEN
  # make sure you .secrets file has new line added at the end using LF only
  { IFS=$'\n' read -r SOURCE_ACCESS_TOKEN && IFS=$'\n' read -r TARGET_ACCESS_TOKEN; } < .secrets
fi

dryRun=false

baseUrlSourceGitlabApi="https://${SOURCE_GITLAB}/api/v4"
authHeaderSourceGitlab="PRIVATE-TOKEN: ${SOURCE_ACCESS_TOKEN}"
baseUrlTargetGitlabApi="https://${TARGET_GITLAB}/api/v4"
baseUrlTargetGitlab="https://${TARGET_GITLAB}"
authHeaderTargetGitlab="PRIVATE-TOKEN: ${TARGET_ACCESS_TOKEN}"


function urlencode() {
	local LANG=C i c e=''
	for ((i=0;i<${#1};i++)); do
    c=${1:${i}:1}
		[[ "$c" =~ [a-zA-Z0-9\.\~\_\-] ]] || printf -v c '%%%02X' "'$c"
    e+="$c"
	done
  echo "$e"
}

function getObjects() {
  local type=${1-}
  if [[ "$type" == "archived" ]]; then
    type="&archived=true"
  fi

  local headerUrl
  local pages
  headerUrl=$(curl ${CURL_PARAMS} -sS --head --header "${authHeaderSourceGitlab}" "${groupProjectsUrl}${type}")
  pages=$(grep -ioP '(?<=x-total-pages: ).*' <<< "${headerUrl}" | tr -d '\r')

  for ((i=1; i<="${pages}"; i++)); do
    local -a objects
    mapfile -t objects < <(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${groupProjectsUrl}${type}&page=${i}" | jq -r '.[].path_with_namespace')
    local object
    for object in "${objects[@]}"; do
      echo "${object}"
    done
  done
}

function migrateGroup() {
  local groupPath=$1
  echo "Migrating group '${groupPath}'"

  if [[ "$MIGRATE_GROUP_VARIABLES" == "yes"  ]]; then
    migrateGroupVariables "${groupPath}"
  fi

  if [[ "$MIGRATE_BADGES" == "yes"  ]]; then
    migrateBadges "${groupPath}" "groups"
  fi

  local groupPathEncoded
  groupPathEncoded=$(urlencode "${groupPath}")
  local groupsUrl="${baseUrlSourceGitlabApi}/groups/${groupPathEncoded}"

  # https://docs.gitlab.com/ee/api/groups.html#list-a-groups-projects
  local groupProjectsUrl="${groupsUrl}/projects?per_page=100&simple=true"

  local -a projects
  mapfile -t projects <<< "$(getObjects)"

  local -a archivedProjects
  mapfile -t archivedProjects <<< "$(getObjects "archived")"

  if [[ "${#archivedProjects[@]}" == 1 ]]; then
    archivedProjects=()
  fi

  local -a allProjects=("${projects[@]}" "${archivedProjects[@]}")
  local -a allProjectsFiltered

  # NOTE: Gitlab might return projects outside the source group specified.
  # These projects seems to be related to the user that does the migration. The
  # API doesn't seems to have an option to exclude these projects, so we filter
  # them here, making sure that the prefix matches the source path.
  for project in "${allProjects[@]}"; do
    if [[ "${project}" =~ ^${SOURCE_PATH} ]]; then
      allProjectsFiltered+=(${project})
    else
      echo "Skipping project outside group: ${project}"
    fi
  done

  migrateProjects "${allProjectsFiltered[@]}"

  # https://docs.gitlab.com/ee/api/groups.html#list-a-groups-subgroups
  # TODO do we need to follow paging or ist it safe to assume that no group has more than 100 subgroups?
  local -a subGroups
  mapfile -t subGroups < <(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${groupsUrl}/subgroups?per_page=100" | jq -r --arg gp "${groupPath}" '$gp + "/" + .[].path')
  for subGroup in "${subGroups[@]}"; do
    createGroup "${subGroup}"
    migrateGroup "${subGroup}"
  done
}

function createGroup() {
  local groupPath=$1
  local groupPathEncoded
  groupPathEncoded=$(urlencode "${groupPath}")
  local groupUrl="${baseUrlSourceGitlabApi}/groups/${groupPathEncoded}?with_projects=false"
  local groupPathTargetGitlab="${groupPath/$SOURCE_PATH/$TARGET_PATH}"
  local groupPathTargetGitlabEncoded
  groupPathTargetGitlabEncoded=$(urlencode "${groupPathTargetGitlab}")
  local groupUrlTargetGitlab="${baseUrlTargetGitlabApi}/groups/${groupPathTargetGitlabEncoded}"

  local status
  status=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${groupUrlTargetGitlab}")
  if [[ "$status" == "404" ]]; then
    echo -n -e "Creating subgroup '${groupPath}: "

    local parentId parentGroupPathTargetGitlab parentGroupPathEncodedTargetGitlab
    parentGroupPathTargetGitlab=$(dirname "${groupPathTargetGitlab}")
    parentGroupPathEncodedTargetGitlab=$(urlencode "${parentGroupPathTargetGitlab}")
    parentId=$(curl ${CURL_PARAMS} -sS --header "${authHeaderTargetGitlab}" "${baseUrlTargetGitlabApi}/groups/${parentGroupPathEncodedTargetGitlab}" | jq -r '.id')

    local groupObject
    groupObject=$(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${groupUrl}" | jq --arg pid "${parentId}" -rc 'del(.id, .web_url, .full_name, .full_path, .runners_token, .parent_id) | .visibility="private" |.request_access_enabled=false | .require_two_factor_authentication=true | .share_with_group_lock=true | .parent_id=$pid | del(.full_path)')

    local createResponse createMessage createStatus
    createResponse=$(curl ${CURL_PARAMS} -sS -w "\n%{http_code}\n" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"${groupObject}" "${baseUrlTargetGitlabApi}/groups")
    { IFS= read -r createMessage && IFS= read -r createStatus; } <<< "${createResponse}"
    if [[ "${createStatus}" != "201" ]]; then
      echo "Error creating ${TARGET_GITLAB} group. Status code: ${createStatus}. Message: ${createMessage}"
      exit 1;
    fi
    echo "Done"
  else
    if [[ "$status" != "200" ]]; then
      echo "Error getting ${TARGET_GITLAB} group. Status code $status"
      exit 1;
    fi
  fi
}

function migrateProjects() {
  local projects=("$@")
  for project in "${projects[@]}"; do
    echo -e "\tMigrating project '${project}': "

    if isTargetProjectExists "${project}"; then
        echo -e "\t\tSkipping already existing target project."
        continue
    fi

    local archived
    archived=$(isArchived "${project}")
    if [[ "$MIGRATE_ARCHIVED_PROJECTS" == "yes" && "$archived" == "true" ]]; then
        echo -n -e "\t\tUnarchiving original project: "
        archiveProject "${project}" "${authHeaderSourceGitlab}" "${baseUrlSourceGitlabApi}" "true"
        echo " Done"
    fi
    migrateProject "${project}"

    if [[ "$MIGRATE_PROJECT_VARIABLES" == "yes"  ]]; then
        migrateProjectVariables "${project}"
    fi

    if [[ "$MIGRATE_HOOKS" == "yes"  ]]; then
        migrateHooks "${project}"
    fi

    if [[ "$ADD_DESCRIPTION" == "yes"  ]]; then
        addMigrationInfoToSourceProjectDescription "${project}"
    fi

    if [[ "$MIGRATE_ARCHIVED_PROJECTS" == "yes" && "$archived" == "true" ]]; then
        archiveProjects "${project}"
    fi

    if [[ "$ARCHIVE_AFTER_MIGRATION" == "yes" && "$archived" == "false" ]]; then
        archiveOriginalProject "${project}"
    fi

  done
}

function addMigrationInfoToSourceProjectDescription() {
    local project=$1
    local projectEncoded
    projectEncoded=$(urlencode "${project}")

    local projectUrl="${baseUrlSourceGitlabApi}/projects/${projectEncoded}"
    local migratedProject="${project/$SOURCE_PATH/$TARGET_PATH}"
    local migratedProjectUrl="${baseUrlTargetGitlab}/${migratedProject}"

    local projectDescription
    projectDescription=$(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${projectUrl}" | jq -r '.description')
    local updatedProjectDescription=":warning: Project moved to ${migratedProjectUrl}
${projectDescription}"

    echo -n -e "\t\tUpdate project description: "
    local updateDescResponse updateDescStatus updateDescMessage
    updateDescResponse=$(curl ${CURL_PARAMS} -sS -w "\n%{http_code}\n" -X PUT --header "${authHeaderSourceGitlab}" "${projectUrl}" --form "description=${updatedProjectDescription}")
    { IFS= read -r updateDescMessage && IFS= read -r updateDescStatus; } <<< "${updateDescResponse}"
    if [[ "${updateDescStatus}" != "200" ]]; then
      echo "Error updating project description. Status code: ${updateDescStatus}. Message: ${updateDescResponse}"
      exit 1;
    fi
    echo " Done"
}

function archiveOriginalProject() {
    local project=$1
    echo -n -e "\t\tArchiving original project: "
    archiveProject "${project}" "${authHeaderSourceGitlab}" "${baseUrlSourceGitlabApi}"
    echo " Done"
}

function archiveProjects() {
    local project=$1
    archiveOriginalProject "${project}"

    echo -n -e "\t\tArchiving migrated project: "
    local migratedProject="${project/$SOURCE_PATH/$TARGET_PATH}"

    archiveProject "${migratedProject}" "${authHeaderTargetGitlab}" "${baseUrlTargetGitlabApi}"
    echo " Done"
}

function archiveProject() {
    local project=$1
    local authHeader=$2
    local baseUrl=$3
    local unarchive=${4-}
    if [[ -n "${unarchive}" ]]; then
        unarchive="un"
    fi
    local projectEncoded
    projectEncoded=$(urlencode "${project}")

    local url="${baseUrl}/projects/${projectEncoded}/${unarchive}archive"

    local archiveResponse archiveStatus archiveMessage
    archiveResponse=$(curl ${CURL_PARAMS} -sS -w "\n%{http_code}\n" -X POST --header "${authHeader}" "${url}")
    { IFS= read -r archiveMessage && IFS= read -r archiveStatus; } <<< "${archiveResponse}"

    if [[ "${archiveStatus}" != "201" ]]; then
        echo -n "Error ${unarchive}archiving project: $archiveStatus $archiveMessage"
        exit 1;
    fi
}

function migrateProject() {
  local project=$1
  echo -n -e "\t\tExporting from ${SOURCE_GITLAB}: "

  local projectEncoded
  projectEncoded=$(urlencode "${project}")
  # https://docs.gitlab.com/ee/api/project_import_export.html#schedule-an-export
  local projectExportUrl="${baseUrlSourceGitlabApi}/projects/${projectEncoded}/export"
  if (${dryRun}); then
    echo "${projectExportUrl}"
  else
    local export
    export=$(curl ${CURL_PARAMS} -sS --request POST --header "${authHeaderSourceGitlab}" "${projectExportUrl}" | jq -r '.message')
    if [[ "$export" != "202 Accepted" ]]; then
      echo "Error triggering export: $export"
      exit 1;
    fi
    while true; do
      local -a exportStatus
      mapfile -t exportStatus < <(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${projectExportUrl}" | jq -r '.export_status, ._links.api_url')
      if [[ "${exportStatus[0]}" == "finished" ]]; then
        echo " Done ${exportStatus[1]}"
        local fileName
        fileName=$(downloadFile "${exportStatus[1]}")
        importProject "${project}" "${fileName}"
        break
      fi
      if [[ "${exportStatus[0]}" == "none" ]]; then
        echo -n " None"
        break
      fi
      if [[ "${exportStatus[0]}" == "queued" ]]; then
        echo -n "."
        sleep 5
        continue
      fi
      if [[ "${exportStatus[0]}" == "started" ]]; then
        echo -n "."
        sleep 5
        continue
      fi
      if [[ "${exportStatus[0]}" == "regeneration_in_progress" ]]; then
        echo -n "."
        sleep 5
        continue
      fi
      echo ${exportStatus[0]}
      break
    done
  fi
}

function isArchived() {
  local project=$1
  local projectEncoded
  projectEncoded=$(urlencode "${project}")
  local projectUrl="${baseUrlSourceGitlabApi}/projects/${projectEncoded}"
  local archived
  archived=$(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${projectUrl}" | jq -r '.archived')
  echo "$archived"
}

function downloadFile () {
  local downloadUrl=$1
  local tempPath="tmp.tar.gz"
  curl ${CURL_PARAMS} -sS -o "$tempPath" --header "$authHeaderSourceGitlab" "$downloadUrl"
  echo "$tempPath"
}

function importProject () {
  local project=$1
  local fileName=$2
  echo -n -e "\t\tImporting to ${TARGET_GITLAB}: "

  # https://docs.gitlab.com/ee/api/project_import_export.html#import-a-file
  local importUrl="${baseUrlTargetGitlabApi}/projects/import"
  local projectPath="${project/$SOURCE_PATH/$TARGET_PATH}"
  local projectName=$(basename "${projectPath}")
  local projectNamespace=$(dirname "${projectPath}")

  local importResponse importStatus importMessage
  importResponse=$(curl ${CURL_PARAMS} -sS -w "\n%{http_code}\n" -X POST --header "${authHeaderTargetGitlab}" --form "path=${projectName}" --form "namespace=${projectNamespace}" --form "file=@${fileName}" "${importUrl}")
  { IFS= read -r importMessage && IFS= read -r importStatus; } <<< "${importResponse}"

  if [[ "${importStatus}" != "201" ]]; then
    echo -n "Error starting import: $importStatus $importMessage"
    exit 1;
  fi

  local projectPathEncoded
  projectPathEncoded=$(urlencode "${projectPath}")
  # https://docs.gitlab.com/ee/api/project_import_export.html#import-status
  local importStatusUrl="${baseUrlTargetGitlabApi}/projects/${projectPathEncoded}/import"
  while true; do
    importStatus=$(curl ${CURL_PARAMS} -sS --header "${authHeaderTargetGitlab}" "${importStatusUrl}" | jq -r '.import_status')
    if [[ "${importStatus}" == "finished" ]]; then
      echo -n " Done"
      break
    fi
    if [[ "${importStatus}" == "none" ]]; then
      echo -n " None"
      break
    fi
    if [[ "${importStatus}" == "failed" ]]; then
      echo -n " Failed to import the project"
      exit 1
    fi
    echo -n "."
    sleep 5
  done
  rm "$fileName"
  echo ""
}

function isTargetProjectExists () {
    local project=$1
    local projectPath="${project/$SOURCE_PATH/$TARGET_PATH}"
    local projectPathEncoded
    projectPathEncoded=$(urlencode "${projectPath}")

    projectResponse=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${baseUrlTargetGitlabApi}/projects/${projectPathEncoded}")
    if [[ "${projectResponse}" == "200" ]]; then
        return 0
    fi
    return 1
}

function migrateVariables ()  {
  local entity=$1
  local type=$2
  echo -n -e "\t\tImporting variables: "

  local entityEncoded
  entityEncoded=$(urlencode "${entity}")
  local entityTargetGitlab="${entity/$SOURCE_PATH/$TARGET_PATH}"
  local entityEncodedTargetGitlab
  entityEncodedTargetGitlab=$(urlencode "${entityTargetGitlab}")
  # https://docs.gitlab.com/ee/api/project_level_variables.html
  local variableUrlSourceGitlab="${baseUrlSourceGitlabApi}/${type}/${entityEncoded}/variables?per_page=100"
  local variableUrlTargetGitlab="${baseUrlTargetGitlabApi}/${type}/${entityEncodedTargetGitlab}/variables"

  local response=$(curl ${CURL_PARAMS} -sS -w "\n%{http_code}" --header "${authHeaderSourceGitlab}" "${variableUrlSourceGitlab}")
  processCurlHttpResponse "$response"
  if [[ "${httpResponse['status']}" == "403" ]]; then
    echo "Skipping variables as CI/CD pipelines are disabled"
    return
  fi

  if [[ "${httpResponse['status']}" == "200" ]]; then
    local -a variables
    mapfile -t variables < <(echo -n "${httpResponse['body']}" | jq -rc '.[]')
    #echo "${variables[@]}"
    local variable
    for variable in "${variables[@]}"; do
    local varKey=$(jq -r '.key' <<< "${variable}")
    local status=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${variableUrlTargetGitlab}/${varKey}")
    if [[ "$status" == "200" ]]; then
      echo -n -e "Skipping already existing variable '${varKey}'. "
      continue
    else
      local importStatus
      importStatus=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$variable" "${variableUrlTargetGitlab}")
      if [[ "$importStatus" != "201" ]]; then
        echo "Error creating variable. Got status code $importStatus"
        exit 1
      fi
    fi
    echo -n "."
    done
    echo " Done"
  else
    echo "Error retrieving variables. Response: ${httpResponse['status']} - ${httpResponse['body']}"
    exit 1;
  fi
}

function migrateProjectVariables() {
  local project=$1
  migrateVariables "${project}" "projects"
}

function migrateGroupVariables() {
  local group=$1
  migrateVariables "${group}" "groups"
}

function migrateHooks () {
  local project=$1
  echo -n -e "\t\tImporting hooks: "

  local projectEncoded
  projectEncoded=$(urlencode "${project}")
  local projectTargetGitlab="${project/$SOURCE_PATH/$TARGET_PATH}"
  local projectEncodedTargetGitlab
  projectEncodedTargetGitlab=$(urlencode "${projectTargetGitlab}")
  # https://docs.gitlab.com/ee/api/projects.html#list-project-hooks
  local projectHooksUrl="${baseUrlSourceGitlabApi}/projects/${projectEncoded}/hooks?per_page=100"
  local projectHookUrlTargetGitlab="${baseUrlTargetGitlabApi}/projects/${projectEncodedTargetGitlab}/hooks"
  local -a hooks
  mapfile -t hooks < <(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${projectHooksUrl}" | jq -rc '.[]')
  local hook
  for hook in "${hooks[@]}"; do
    local status
    status=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$hook" "${projectHookUrlTargetGitlab}")
     if [[ "$status" != "201" ]]; then
      echo "Error creating project hooks. Got status code $status"
      exit 1
    fi
    echo -n "."
  done
  echo " Done"
}

function migrateBadges ()  {
  local entity=$1
  local type=$2
  echo -n -e "\t\tImporting badges: "

  local entityEncoded
  entityEncoded=$(urlencode "${entity}")
  local entityTargetGitlab="${entity/$SOURCE_PATH/$TARGET_PATH}"
  local entityEncodedTargetGitlab
  entityEncodedTargetGitlab=$(urlencode "${entityTargetGitlab}")
  # https://docs.gitlab.com/ee/api/group_badges.html
  local badgesUrlSourceGitlab="${baseUrlSourceGitlabApi}/${type}/${entityEncoded}/badges?per_page=100"
  local badgesUrlTargetGitlab="${baseUrlTargetGitlabApi}/${type}/${entityEncodedTargetGitlab}/badges"

  local -a badges
  mapfile -t badges < <(curl ${CURL_PARAMS} -sS --header "${authHeaderSourceGitlab}" "${badgesUrlSourceGitlab}" | jq -rc '.[] | del(.id, .rendered_link_url, .rendered_image_url, .kind)')
  #echo "${badges[@]}"
  local badge
  for badge in "${badges[@]}"; do
    local badgeId=$(jq -r '.id' <<< "${badge}")
    local status=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${badgesUrlTargetGitlab}/${badgeId}")
    if [[ "$status" == "200" ]]; then
      echo -n -e "Skipping already existing badge '${badgeId}'. "
      continue
    fi
    local importStatus
    importStatus=$(curl ${CURL_PARAMS} -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$badge" "${badgesUrlTargetGitlab}")
    if [[ "${importStatus}" != "201" ]]; then
      echo "Error creating badge. Got status code ${importStatus}"
      exit 1
    fi
    echo -n "."
  done
  echo " Done"
}

declare -A httpResponse
# the Curl command call has to be configured to append the status code in a newline to the response e.g. curl -s -w "\n%{http_code}" ...
function processCurlHttpResponse() {
    local curlResponse=$1

    httpResponse['status']=$(tail -n1 <<< "$curlResponse")
    httpResponse['body']=$(sed '$ d' <<< "$curlResponse")
#    echo "Status: ${httpResponse['status']}"
#    echo "Body: ${httpResponse['body']}"
}

migrateGroup "${SOURCE_PATH}"
