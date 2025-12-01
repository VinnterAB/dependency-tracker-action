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
upload_bom=$(curl $INSECURE $VERBOSE -s --location --request POST $DTRACK_URL/api/v1/bom \
--header "X-Api-Key: $DTRACK_KEY" \
--header "Content-Type: multipart/form-data" \
--form "autoCreate=true" \
$PROJECT_UUID_PARAM \
$PARENT_UUID_PARAM \
$PROJECT_NAME_PARAM \
$PROJECT_VERSION_PARAM \
--form "isLatest=$ISLATEST" \
--form "bom=@sbom.xml")

token=$(echo $upload_bom | jq ".token" | tr -d "\"")
echo "[*] BoM file succesfully uploaded with token $token"


if [ -z $token ]; then
    echo "[-]  The BoM file has not been successfully processed by OWASP Dependency Track"
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

echo "riskscore=$risk_score" >> "$GITHUB_OUTPUT"
