#!/bin/bash set -eu

PUSH=
FORCE=

for i in "$@"
do
case $i in
    # Perform all git commands, Do not use locally
    --push)
      PUSH="true"
    ;;
    # Force update the cask even if it's already got the latest version
    --force)
      FORCE="true"
    ;;
esac
done

function check_fork {
  git ls-remote --exit-code fork > /dev/null 2>&1
  if test $? = 1; then
    git remote add fork git@github.com:adoptopenjdk-github-bot/homebrew-openjdk.git
  fi
}

function check_hub {
  command -v hub > /dev/null 2>&1
  if test $? = 1; then
    echo "Installing hub"
    os=$(uname | awk '{print tolower($0)}')
    wget --quiet "https://github.com/github/hub/releases/download/v2.12.3/hub-$os-amd64-2.12.3.tgz"
    tar -xf hub-$os-amd64-2.12.3.tgz
    export PATH="$PWD/hub-$os-amd64-2.12.3/bin:$PATH"
    rm -rf hub-$os-amd64-2.12.3.tgz
  fi
  # Check that hub is in the PATH
  which hub
}

function update_casks {
  cd Casks

  if [ "$PUSH" == "true" ]; then
    git fetch --all
    git reset --hard upstream/master
  fi

  for filename in adoptopenjdk*.rb; do
    echo "Checking $filename"
    case $filename in
      *openj9*) jvm_impl="openj9" ;;
      *) jvm_impl="hotspot" ;;
    esac

    case $filename in
      *jre*) type="jre" ;;
      *) type="jdk" ;;
    esac

    case $filename in
      *large.rb) heap="large" ;;
      *) heap="normal" ;;
    esac

    version=$(echo $filename | grep -Eo 'openjdk[0-9]{1,2}')

    cask_url=$(cat $filename | grep 'url ' | awk '{print $2}' | tr -d "'")
    case $cask_url in
      *.tar.gz*) echo "detected a tar.gz, skipping!" ;;
      *)
        api_latest=$(curl --silent "https://api.adoptopenjdk.net/v3/assets/feature_releases/${version//[!0-9]/}/ga?architecture=x64&heap_size=$heap&image_type=$type&jvm_impl=$jvm_impl&os=mac&page=0&page_size=1&vendor=adoptopenjdk")
        is_installer=$(echo $api_latest | grep installer)

        if [ -z $is_installer ]; then
          echo "Skipping because no pkg available"
        else
          api_url=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['installer']['link'])")

          if [ "$api_url" != "$cask_url" ] || [ "$FORCE" == "true" ]; then
            echo "Updating $filename"
            cask_sha256=$(cat $filename | grep 'sha256 ' | awk '{print $2}' | tr -d "'")
            api_sha256=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['installer']['checksum'])")

            cask_installer_name=$(cat $filename | grep 'pkg ' | awk '{print $2}' | tr -d "'")
            api_installer_name=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['installer']['name'])")
            cask_version=$(cat $filename | grep 'version ' | awk '{print $2}' | tr -d "'")

            if [ $version == "openjdk8" ]; then
              security=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['version_data']['security'])")
              build=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['version_data']['openjdk_version'])" | cut -d "-" -f 2)
              api_version="8,$security:$build"
              appcast="https://github.com/adoptopenjdk/openjdk#{version.before_comma}-binaries/releases/latest"
            else
              api_version=$(echo $api_latest | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['version_data']['openjdk_version'])" | sed 's/+/,/g')
              appcast="https://github.com/AdoptOpenJDK/openjdk#{version.major}-binaries/releases/latest"
            fi

            if [ "$PUSH" == "true" ]; then
              git checkout "$version-$jvm_impl-$type-$heap" || git checkout -b "$version-$jvm_impl-$type-$heap"
              git reset --hard upstream/master
            fi

            name="AdoptOpenJDK ${version//[!0-9]/}"
            identifier="net.adoptopenjdk.${version//[!0-9]/}"

            if [ "$jvm_impl" == "openj9" ]; then
              name+=" (OpenJ9)"
              identifier+="-openj9"
            fi

            if [ "$type" == "jre" ]; then
              name+=" (JRE)"
              identifier+=".jre"
            else 
              identifier+=".jdk"
            fi

            if [ "$heap" == "large" ]; then
              name+=" (XL)"
            fi

            cat ../Templates/adoptopenjdk.rb.tmpl  \
            | sed -E "s/\\{cask_name\\}/${filename%.*}/g" \
            | sed -E "s/\\{version_number\\}/$api_version/g" \
            | sed -E "s/\\{shasum\\}/$api_sha256/g" \
            | sed -E "s|\\{cask_url\\}|$api_url|g" \
            | sed -E "s|\\{appcast\\}|$appcast|g" \
            | sed -E "s/\\{name\\}/$name/g" \
            | sed -E "s/\\{filename\\}/$api_installer_name/g" \
            | sed -E "s/\\{identifier\\}/$identifier/g" \
            >$filename ; \

            if [ "$PUSH" == "true" ]; then
              git add $filename
              git commit -m "update $filename to $api_version"
              git push -f fork "$version-$jvm_impl-$type-$heap"
              hub pull-request --base adoptopenjdk:master --head "$version-$jvm_impl-$type-$heap" -m "update $filename to $api_version"
            fi
          fi
        fi
    esac
  done
}

if [ "$PUSH" == "true" ]; then
  check_fork
  check_hub
fi

update_casks

cd -
