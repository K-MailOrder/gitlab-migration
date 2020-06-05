#!/bin/bash
set -euo pipefail

SOURCE_GITLAB=${SOURCE_GITLAB:=git.mycpompany.de}
TARGET_GITLAB=${TARGET_GITLAB:=gitlab.com}
printf "Enter source group path at ${SOURCE_GITLAB} (e.g. project/team): "
read -r SOURCE_PATH
printf "Enter target group path at ${TARGET_GITLAB} (e.g. mycompany/project/team): "
read -r TARGET_PATH
printf "Archive original projects at ${SOURCE_GITLAB} after migration? (yes/no): "
read -r ARCHIVE_AFTER_MIGRATION
#SOURCE_PATH=""
#TARGET_PATH=""
#ARCHIVE_AFTER_MIGRATION="no"

unset -v sourceGitlabPrivateAccessToken targetGitlabPrivateAccessToken
{ IFS=$'\n\r' read -r sourceGitlabPrivateAccessToken && IFS=$'\n\r' read -r targetGitlabPrivateAccessToken; } < .secrets

dryRun=false

baseUrlSourceGitlabApi="https://${SOURCE_GITLAB}/api/v4"
authHeaderSourceGitlab="PRIVATE-TOKEN: ${sourceGitlabPrivateAccessToken}"
baseUrlTargetGitlabApi="https://${TARGET_GITLAB}/api/v4"
baseUrlTargetGitlab="https://${TARGET_GITLAB}"
authHeaderTargetGitlab="PRIVATE-TOKEN: ${targetGitlabPrivateAccessToken}"


function urlencode() {
	local LANG=C i c e=''
	for ((i=0;i<${#1};i++)); do
    c=${1:${i}:1}
		[[ "$c" =~ [a-zA-Z0-9\.\~\_\-] ]] || printf -v c '%%%02X' "'$c"
    e+="$c"
	done
  echo "$e"
}

function migrateGroup() {
  local groupPath=$1
  echo "Migrating group '${groupPath}'"

  migrateGroupVariables "${groupPath}"
  migrateBadges "${groupPath}" "groups"

  local groupPathEncoded
  groupPathEncoded=$(urlencode "${groupPath}")
  local groupsUrl="${baseUrlSourceGitlabApi}/groups/${groupPathEncoded}"

  # https://docs.gitlab.com/ee/api/groups.html#list-a-groups-projects
  # TODO do we need to follow paging or ist it safe to assume that no group has more than 100 projects?
  local groupProjectsUrl="${groupsUrl}/projects?per_page=100&simple=true"
  local -a projects
  mapfile -t projects < <(curl -sS --header "${authHeaderSourceGitlab}" "${groupProjectsUrl}" | jq -r '.[].path_with_namespace')
  local -a archivedProjects
  mapfile -t archivedProjects < <(curl -sS --header "${authHeaderSourceGitlab}" "${groupProjectsUrl}&archived=true" | jq -r '.[].path_with_namespace')
  local -a allProjects=("${projects[@]}" "${archivedProjects[@]}")
  migrateProjects "${allProjects[@]}"

  # https://docs.gitlab.com/ee/api/groups.html#list-a-groups-subgroups
  local -a subGroups
  mapfile -t subGroups < <(curl -sS --header "${authHeaderSourceGitlab}" "${groupsUrl}/subgroups?per_page=100" | jq -r --arg gp "${groupPath}" '$gp + "/" + .[].path')
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
  status=$(curl -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${groupUrlTargetGitlab}")
  if [[ "$status" == "404" ]]; then
    echo -n -e "Creating subgroup '${groupPath}: "

    local parentId parentGroupPathTargetGitlab parentGroupPathEncodedTargetGitlab
    parentGroupPathTargetGitlab=$(dirname "${groupPathTargetGitlab}")
    parentGroupPathEncodedTargetGitlab=$(urlencode "${parentGroupPathTargetGitlab}")
    parentId=$(curl -sS --header "${authHeaderTargetGitlab}" "${baseUrlTargetGitlabApi}/groups/${parentGroupPathEncodedTargetGitlab}" | jq -r '.id')

    local groupObject
    groupObject=$(curl -sS --header "${authHeaderSourceGitlab}" "${groupUrl}" | jq --arg pid "${parentId}" -rc 'del(.id, .web_url, .full_name, .full_path, .runners_token, .parent_id) | .visibility="private" |.request_access_enabled=false | .require_two_factor_authentication=true | .share_with_group_lock=true | .parent_id=$pid | del(.full_path)')

    local createResponse createMessage createStatus
    createResponse=$(curl -sS -w "\n%{http_code}\n" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"${groupObject}" "${baseUrlTargetGitlabApi}/groups")
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
    if [[ "$archived" == "true" ]]; then
        echo -n -e "\t\tUnarchiving original project: "
        archiveProject "${project}" "${authHeaderSourceGitlab}" "${baseUrlSourceGitlabApi}" "true"
        echo " Done"
    fi
    migrateProject "${project}"
    migrateProjectVariables "${project}"
    migrateHooks "${project}"

    addMigrationInfoToSourceProjectDescription "${project}"

    if [[ "$archived" == "true" ]]; then
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
    projectDescription=$(curl -sS --header "${authHeaderSourceGitlab}" "${projectUrl}" | jq -r '.description')
    local updatedProjectDescription=":warning: Project moved to ${migratedProjectUrl}
${projectDescription}"

    echo -n -e "\t\tUpdate project description: "
    local updateDescResponse updateDescStatus updateDescMessage
    updateDescResponse=$(curl -sS -w "\n%{http_code}\n" -X PUT --header "${authHeaderSourceGitlab}" "${projectUrl}" --form "description=${updatedProjectDescription}")
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
    archiveResponse=$(curl -sS -w "\n%{http_code}\n" -X POST --header "${authHeader}" "${url}")
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
    export=$(curl -sS --request POST --header "${authHeaderSourceGitlab}" "${projectExportUrl}" | jq -r '.message')
    if [[ "$export" != "202 Accepted" ]]; then
      echo "Error triggering export: $export"
      exit 1;
    fi
    while true; do
      local -a exportStatus
      mapfile -t exportStatus < <(curl -sS --header "${authHeaderSourceGitlab}" "${projectExportUrl}" | jq -r '.export_status, ._links.api_url')
      if [[ "${exportStatus[0]}" == "finished" ]]; then
        echo " Done ${exportStatus[1]}"
        local fileName
        fileName=$(downloadFile "${exportStatus[1]}")
        importProject "${project}" "${fileName}"
        break
      fi
      echo -n "."
      sleep 5
    done
  fi
}

function isArchived() {
  local project=$1
  local projectEncoded
  projectEncoded=$(urlencode "${project}")
  local projectUrl="${baseUrlSourceGitlabApi}/projects/${projectEncoded}"
  local archived
  archived=$(curl -sS --header "${authHeaderSourceGitlab}" "${projectUrl}" | jq -r '.archived')
  echo "$archived"
}

function downloadFile () {
  local downloadUrl=$1
  local tempPath="tmp.tar.gz"
  curl -sS -o "$tempPath" --header "$authHeaderSourceGitlab" "$downloadUrl"
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
  importResponse=$(curl -sS -w "\n%{http_code}\n" -X POST --header "${authHeaderTargetGitlab}" --form "path=${projectName}" --form "namespace=${projectNamespace}" --form "file=@${fileName}" "${importUrl}")
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
    importStatus=$(curl -sS --header "${authHeaderTargetGitlab}" "${importStatusUrl}" | jq -r '.import_status')
    if [[ "${importStatus}" == "finished" ]]; then
      echo -n " Done"
      break
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

    projectResponse=$(curl -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${baseUrlTargetGitlabApi}/projects/${projectPathEncoded}")
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

  local -a variables
  mapfile -t variables < <(curl -sS --header "${authHeaderSourceGitlab}" "${variableUrlSourceGitlab}" | jq -rc '.[]')
  #echo "${variables[@]}"
  local variable
  for variable in "${variables[@]}"; do
    local varKey=$(jq -r '.key' <<< "${variable}")
    local status=$(curl -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${variableUrlTargetGitlab}/${varKey}")
    if [[ "$status" == "200" ]]; then
      echo -n -e "Skipping already existing variable '${varKey}'. "
      continue
    else
      local importStatus
      importStatus=$(curl -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$variable" "${variableUrlTargetGitlab}")
      if [[ "$importStatus" != "201" ]]; then
        echo "Error creating variable. Got status code $importStatus"
        exit 1
      fi
    fi
    echo -n "."
  done
  echo " Done"
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
  mapfile -t hooks < <(curl -sS --header "${authHeaderSourceGitlab}" "${projectHooksUrl}" | jq -rc '.[]')
  local hook
  for hook in "${hooks[@]}"; do
    local status
    status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$hook" "${projectHookUrlTargetGitlab}")
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
  mapfile -t badges < <(curl -sS --header "${authHeaderSourceGitlab}" "${badgesUrlSourceGitlab}" | jq -rc '.[] | del(.id, .rendered_link_url, .rendered_image_url, .kind)')
  #echo "${badges[@]}"
  local badge
  for badge in "${badges[@]}"; do
    local badgeId=$(jq -r '.id' <<< "${badge}")
    local status=$(curl -sS -o /dev/null -w "%{http_code}" --header "${authHeaderTargetGitlab}" "${badgesUrlTargetGitlab}/${badgeId}")
    if [[ "$status" == "200" ]]; then
      echo -n -e "Skipping already existing badge '${badgeId}'. "
      continue
    fi
    local importStatus
    importStatus=$(curl -sS -o /dev/null -w "%{http_code}" -X POST --header "${authHeaderTargetGitlab}" --header "Content-Type: application/json" -d ''"$badge" "${badgesUrlTargetGitlab}")
    if [[ "${importStatus}" != "201" ]]; then
      echo "Error creating badge. Got status code ${importStatus}"
      exit 1
    fi
    echo -n "."
  done
  echo " Done"
}

migrateGroup "${SOURCE_PATH}"
