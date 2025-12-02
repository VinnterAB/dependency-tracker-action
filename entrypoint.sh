#!/bin/sh -l

DTRACK_URL=$1
DTRACK_KEY=$2
LANGUAGE=$3
VERSION=$4
ACTION=$5
ISLATEST=$6

# Use provided version or fallback to git ref
if [ -z "$VERSION" ]; then
    VERSION=$GITHUB_REF
fi

# Use provided action or fallback to upload
if [ -z "$ACTION" ]; then
    ACTION="upload"
fi

# Use provided isLatest or fallback to false
if [ -z "$ISLATEST" ]; then
    ISLATEST="false"
fi

#INSECURE="--insecure"
#VERBOSE="--verbose"

curl_timeout_seconds=60

# Access directory where GitHub will mount the repository code
# $GITHUB_ variables are directly accessible in the script
cd $GITHUB_WORKSPACE

# Handle delete action
if [ "$ACTION" = "delete" ]; then
    echo "[*] Retrieving project information for deletion"
    project=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request GET "$DTRACK_URL/api/v1/project/lookup?name=$GITHUB_REPOSITORY&version=$VERSION" \
    --header "X-Api-Key: $DTRACK_KEY")
    
    if [ -z "$project" ] || [ "$project" = "null" ]; then
        echo "[-] Project not found: $GITHUB_REPOSITORY version $VERSION"
        exit 1
    fi
    
    project_uuid=$(echo $project | jq -r ".uuid")
    
    if [ -z "$project_uuid" ] || [ "$project_uuid" = "null" ]; then
        echo "[-] Could not retrieve project UUID for: $GITHUB_REPOSITORY version $VERSION"
        exit 1
    fi
    
    echo "[*] Deleting project with UUID: $project_uuid"
    delete_response=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request DELETE "$DTRACK_URL/api/v1/project/$project_uuid" \
    --header "X-Api-Key: $DTRACK_KEY" \
    --write-out "HTTPSTATUS:%{http_code}")
    
    http_status=$(echo $delete_response | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    
    if [ "$http_status" = "204" ]; then
        echo "[*] Project deleted successfully: $GITHUB_REPOSITORY version $VERSION"
        exit 0
    else
        echo "[-] Failed to delete project. HTTP status: $http_status"
        exit 1
    fi
fi

case $LANGUAGE in
    "nodejs")
        lscommand=$(ls)
        echo "[*] Processing NodeJS BoM"
        apt-get install --no-install-recommends -y nodejs
        npm install
        npm audit fix --force
        if [ ! $? = 0 ]; then
            echo "[-] Error executing npm install. Stopping the action!"
            exit 1
        fi
        npm install -g @cyclonedx/bom
        path="bom.xml"
        cyclonedx-bom --help
        BoMResult=$(cyclonedx-bom -o bom.xml)
        ;;
    
    "python")
        echo "[*]  Processing Python BoM"
        apt-get install --no-install-recommends -y python3 python3-pip
        freeze=$(pip freeze > requirements.txt)
        if [ ! $? = 0 ]; then
            echo "[-] Error executing pip freeze to get a requirements.txt with frozen parameters. Stopping the action!"
            exit 1
        fi
        pip install cyclonedx-bom
        path="bom.xml"
        BoMResult=$(cyclonedx-py -o bom.xml)
        ;;
    
    "golang")
        echo "[*]  Processing Golang BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing go build. Stopping the action!"
            exit 1
        fi
        path="bom.xml"
        BoMResult=$(cyclonedx-go -o bom.xml)
        ;;

    "ruby")
        echo "[*]  Processing Ruby BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing Ruby build. Stopping the action!"
            exit 1
        fi
        apt-get install --no-install-recommends -y build-essential ruby-dev
        gem install cyclonedx-ruby
        path="bom.xml"
        BoMResult=$(cyclonedx-ruby -p ./ -o bom.xml)
        ;;

    "java")
        echo "[*]  Processing Java BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing Java build. Stopping the action!"
            exit 1
        fi
        apt-get install --no-install-recommends -y build-essential default-jdk maven
        path="target/bom.xml"
        BoMResult=$(mvn compile)
        ;;
        
    "dotnet")
        echo "[*]  Processing Golang BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing NuGet (Dotnet) build. Stopping the action!"
            exit 1
        fi
        path="bom.xml/bom.xml"
        dotnet tool install --global CycloneDX
        apt-get update
        # The path to a .sln, .csproj, .vbproj, or packages.config file or the path to 
        # a directory which will be recursively analyzed for packages.config files
        BoMResult=$(dotnet CycloneDX . -o bom.xml)
        ;;
        
    "php")
        echo "[*]  Processing Php Composer BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing Php build. Stopping the action!"
            exit 1
        fi
        apt-get install --no-install-recommends -y build-essential php php-xml php-mbstring
        curl -sS "https://getcomposer.org/installer" -o composer-setup.php
        php composer-setup.php --install-dir=/usr/bin --version=2.0.14 --filename=composer
        composer require --dev cyclonedx/cyclonedx-php-composer
        path="bom.xml"
        BoMResult=$(composer make-bom --spec-version="1.2")
        ;;

    *)
        "[-] Project type not supported: $LANGUAGE"
        exit 1
        ;;
esac    

if [ ! $? = 0 ]; then
    echo "[-] Error generating BoM file: $BomResult. Stopping the action!"
    exit 1
fi

echo "[*] BoM file succesfully generated"

# Cyclonedx CLI conversion
echo "[*] Cyclonedx CLI conversion"
#Does not upload to dtrack when output format = xml (every version available)
cyclonedx-cli convert --input-file $path --output-file sbom.xml --output-format json_v1_2

echo "[*] Uploading BoM file to Dependency Track server"

# 1) First, check if exact name/version combination exists
echo "[*] Looking up exact project match for: $GITHUB_REPOSITORY version $VERSION"
exact_project=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request GET "$DTRACK_URL/api/v1/project/lookup?name=$GITHUB_REPOSITORY&version=$VERSION" \
--header "X-Api-Key: $DTRACK_KEY" 2>/dev/null)

exact_uuid=$(echo $exact_project | jq -r '.uuid // empty')

if [ -n "$exact_uuid" ] && [ "$exact_uuid" != "null" ]; then
    # Case 1: Exact match found - use project UUID directly
    echo "[*] Found exact project match with UUID: $exact_uuid"
    PROJECT_UUID_PARAM="--form project=$exact_uuid"
    PARENT_UUID_PARAM=""
    PROJECT_NAME_PARAM=""
    PROJECT_VERSION_PARAM=""
else
    # 2) Look for parent project with same name but no/empty version
    echo "[*] No exact match found. Looking up parent project with empty version: $GITHUB_REPOSITORY"
    parent_projects=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request GET "$DTRACK_URL/api/v1/project?name=$GITHUB_REPOSITORY" \
    --header "X-Api-Key: $DTRACK_KEY" 2>/dev/null)
    
    # Find project with matching name and empty/null version
    parent_uuid=$(echo $parent_projects | jq -r '.[] | select(.version == null or .version == "") | .uuid' | head -n 1)
    
    if [ -n "$parent_uuid" ] && [ "$parent_uuid" != "null" ]; then
        # Case 2: Parent with empty version found
        echo "[*] Found parent project with empty version, UUID: $parent_uuid"
        PROJECT_UUID_PARAM=""
        PARENT_UUID_PARAM="--form parentUUID=$parent_uuid"
        PROJECT_NAME_PARAM="--form projectName=$GITHUB_REPOSITORY"
        PROJECT_VERSION_PARAM="--form projectVersion=$VERSION"
    else
        # Case 3: No parent found - will auto-create parent with empty version
        echo "[*] No parent project found. Will auto-create parent with empty version"
        # First, create the parent project with empty version
        echo "[*] Creating parent project: $GITHUB_REPOSITORY (empty version)"
        parent_create=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request PUT "$DTRACK_URL/api/v1/project" \
        --header "X-Api-Key: $DTRACK_KEY" \
        --header "Content-Type: application/json" \
        --data-raw "{\"name\":\"$GITHUB_REPOSITORY\",\"version\":\"\"}" 2>/dev/null)
        
        parent_uuid=$(echo $parent_create | jq -r '.uuid // empty')
        
        if [ -n "$parent_uuid" ] && [ "$parent_uuid" != "null" ]; then
            echo "[*] Created parent project with UUID: $parent_uuid"
            PROJECT_UUID_PARAM=""
            PARENT_UUID_PARAM="--form parentUUID=$parent_uuid"
            PROJECT_NAME_PARAM="--form projectName=$GITHUB_REPOSITORY"
            PROJECT_VERSION_PARAM="--form projectVersion=$VERSION"
        else
            echo "[-] Failed to create parent project"
            exit 1
        fi
    fi
fi

# UPLOAD BoM to Dependency track server
echo "[*] Uploading BoM file to Dependency Track server"
upload_bom=$(curl $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request POST $DTRACK_URL/api/v1/bom \
--header "X-Api-Key: $DTRACK_KEY" \
--header "Content-Type: multipart/form-data" \
--form "autoCreate=true" \
$PROJECT_UUID_PARAM \
$PARENT_UUID_PARAM \
$PROJECT_NAME_PARAM \
$PROJECT_VERSION_PARAM \
--form "isLatest=$ISLATEST" \
--form "bom=@sbom.xml" \
--write-out "\n%{http_code}" 2>&1)

curl_exit_code=$?
http_code=$(echo "$upload_bom" | tail -n1)
response_body=$(echo "$upload_bom" | sed '$d')

# Check for curl failure
if [ $curl_exit_code -ne 0 ]; then
    echo "[-] curl command failed with exit code $curl_exit_code"
    echo "Common causes:"
    echo "  - Connection refused: Is Dependency Track running on $DTRACK_URL?"
    echo "  - Network timeout: Server may be unreachable"
    echo "  - DNS resolution failure: Check the URL"
    exit 1
fi

# Check for HTTP 000 (usually indicates connection failure)
if [ "$http_code" = "000" ] || [ -z "$http_code" ]; then
    echo "[-] Failed to connect to Dependency Track server at $DTRACK_URL"
    exit 1
fi

if [ "$http_code" = "400" ]; then
    echo "[-] Invalid BOM detected (HTTP 400). Details:"
    echo "$response_body" | jq -r '
        "Title: " + (.title // "N/A"),
        "Detail: " + (.detail // "N/A"),
        (if .errors then "Validation Errors:" else empty end),
        (if .errors then (.errors[] | "  - " + .) else empty end)
    ' 2>/dev/null || echo "$response_body"
    exit 1
elif [ "$http_code" = "401" ]; then
    echo "[-] Authentication failed (HTTP 401). Check your API key."
    exit 1
elif [ "$http_code" = "403" ]; then
    echo "[-] Access forbidden (HTTP 403). Insufficient permissions."
    exit 1
elif [ "$http_code" = "404" ]; then
    echo "[-] Project not found (HTTP 404)."
    exit 1
elif [ "$http_code" != "200" ]; then
    echo "[-] BOM upload failed with HTTP $http_code"
    echo "Response: $response_body"
    exit 1
fi

token=$(echo "$response_body" | jq -r ".token // empty")
echo "[*] BoM file successfully uploaded with token $token"

if [ -z "$token" ]; then
    echo "[-] The BoM file has not been successfully processed by OWASP Dependency Track"
    echo "Response: $response_body"
    exit 1
fi

echo "[*] Checking BoM processing status"
event_response=$(curl $INSECURE $VERBOSE -s --location --request GET $DTRACK_URL/api/v1/event/token/$token \
--header "X-Api-Key: $DTRACK_KEY")

echo "[*] Event info: $event_response"
processing=$(echo $event_response | jq '.processing')

c=0
max_loops=10
while [ $processing = true ]; do
    sleep 5
    event_response=$(curl  $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request GET $DTRACK_URL/api/v1/event/token/$token \
--header "X-Api-Key: $DTRACK_KEY")
    echo "[*] Event info: $event_response"
    processing=$(echo $event_response | jq '.processing')
    c=$((c + 1))
    if [ "$c" -ge "$max_loops" ]; then
        echo "[-]  Timeout while waiting for processing result. Please check the OWASP Dependency Track status."
        exit 1
    fi
done

echo "[*] OWASP Dependency Track processing completed"

# wait to make sure the score is available, some errors found during tests w/o this wait
sleep 5

echo "[*] Retrieving project information"
project=$(curl  $INSECURE $VERBOSE -s --location --max-time $curl_timeout_seconds --request GET "$DTRACK_URL/api/v1/project/lookup?name=$GITHUB_REPOSITORY&version=$VERSION" \
--header "X-Api-Key: $DTRACK_KEY")

echo "$project"

project_uuid=$(echo $project | jq ".uuid" | tr -d "\"")
risk_score=$(echo $project | jq ".lastInheritedRiskScore")
echo "Project risk score: $risk_score"

# Check for policy violations
policy_violations_fail=$(echo $project | jq ".metrics.policyViolationsFail // 0")
policy_violations_warn=$(echo $project | jq ".metrics.policyViolationsWarn // 0")
policy_violations_info=$(echo $project | jq ".metrics.policyViolationsInfo // 0")
policy_violations_total=$(echo $project | jq ".metrics.policyViolationsTotal // 0")

# Breakdown by type
policy_violations_license=$(echo $project | jq ".metrics.policyViolationsLicenseTotal // 0")
policy_violations_security=$(echo $project | jq ".metrics.policyViolationsSecurityTotal // 0")
policy_violations_operational=$(echo $project | jq ".metrics.policyViolationsOperationalTotal // 0")

echo "[*] Policy Violations Summary:"
echo "    Total: $policy_violations_total (Fail: $policy_violations_fail, Warn: $policy_violations_warn, Info: $policy_violations_info)"
if [ "$policy_violations_license" -gt 0 ]; then
    echo "    License violations: $policy_violations_license"
fi
if [ "$policy_violations_security" -gt 0 ]; then
    echo "    Security violations: $policy_violations_security"
fi
if [ "$policy_violations_operational" -gt 0 ]; then
    echo "    Operational violations: $policy_violations_operational"
fi

echo "riskscore=$risk_score" >> "$GITHUB_OUTPUT"
echo "policy_violations_fail=$policy_violations_fail" >> "$GITHUB_OUTPUT"
echo "policy_violations_warn=$policy_violations_warn" >> "$GITHUB_OUTPUT"
echo "policy_violations_total=$policy_violations_total" >> "$GITHUB_OUTPUT"

# Fail the action if there are policy violations marked as "fail"
if [ "$policy_violations_fail" -gt 0 ]; then
    echo "[-] Build failed due to $policy_violations_fail policy violation(s) with 'fail' severity"
    echo "    View details at: $DTRACK_URL/projects/$project_uuid"
    exit 1
fi
