#!/bin/bash
## This script is a helper script to automatically update Docker containers in a less aggressive way than
#+ existing solutions. It avoids database upgrades and generates its' log in a Prometheus-ready template,
#+ which enables generation of Prometheus alerts when a container is updated, or fails to update.
## The process:
#+ 1. Iterate over the primary container directory and search for Docker stacks
#+ 2. For each Docker stack found, iterate over the images and get their checksum
#+ 3. For each image found, login to docker.io and get the remote checksum
#+    (new repositories, such as quay.io and ghcr.io will be added in the future, if needed)
#+ 4. Compare the checksums. If they differ (assumed newer), pull the remote image
#+ 5. Bring the stack up with the new image
##
#+ The key outcomes of this process (container updated, failed to update, update status undetermined)
#+ Are written to a file monitored by Prometheus. Based on the code assigned to each, Prometheus
#+ sends out an alert (container xyz has been updated, etc).




show_help()
{
    echo "Atarashi Hako - Smartly update container stack"
    echo "  {-s|--stack} [name]             -- Run update process just for specified stack (ex: prometheus)"
    echo "  {-h|--help}                     -- Print this help message and exit"
    exit 0
}

# Pass arguments to the script
flags()
{
    while test $# -gt 0
    do
	case "$1" in
	# If a stack is specified, run the process for that stack only
	(-s|--stack)
	    shift
	    if [[ -d $CONTAINER_DIR/$1 ]]; then
		export CONTAINER_PATHS="$CONTAINER_DIR/$1"
	    else 
		CONTAINER_PATHS="$(find "$CONTAINER_DIR/" -maxdepth 1 -type d -name "*$1*" | head -1)"
		if [[ -n $CONTAINER_PATHS ]]; then
			export CONTAINER_PATHS
		fi
	    fi
	    shift;;
	(-h|--help)
	    show_help;;
	(*) show_help;;
	esac
    done
}
flags "$@"

## Defaults
# Directory to search for stacks
CONTAINER_DIR="/path/to/container/directories/"

# Remember initial execution directory, to return to after the script has finished
LOCAL_DIR=`pwd`

## File to write results to; picked up by Prometheus and yells about changes
PROM_FILE="$CONTAINER_DIR/prometheus/data/atarashi-hako.prom"
## Monitoring codes:
#+ -1 - failed to fetch checksum 
#+  0 - failed to update container
#+  1 - succesfully updated container



# Check if path is already set by user specified stack; otherwise, find all containers.
if [[ -z $CONTAINER_PATHS ]]; then
	CONTAINER_PATHS=$(find $CONTAINER_DIR -maxdepth 2 -type f -name docker-compose.yml ! | xargs dirname )
# Find containers in    ^ base dir     ^ in base container path  ^ by finding compose files    ^ and getting their directory name. 
fi

for container_path in ${CONTAINER_PATHS[@]}; do
	cd $container_path
	echo -e "Working on container directory" "$container_path"
	container_stack=$(basename $container_path)
	echo -e "Working on stack" "$container_stack"
	# Avoid updating tagless images
	container_images="$(cat $container_path/docker-compose.yml | grep -E "image: ([a-z]+)((/)|(:))([a-z]+)?(:)?([a-z0-9].*$)?" | awk '{print $2}')"
#	search for a pattern of something:something with optional :tag	 	      					       print ^ image name
	for container_image in $container_images; do
		echo -e "$container_stack has image" "$container_image"
		echo -e "echo $container_image | awk -F/ '{print \$2}' | sed 's/\:.*//'"
		container_name="$(echo $container_image | awk -F/ '{print $2}' | sed "s/\:.*//")"
#							   remove everything after the : ^
		if [[ -z $container_name ]]; then #&& [[ -n $(echo $container_image | grep -Ev 'postgres|mariadb') ]]; then
			export container_name="$container_image"
		fi
		echo -e "$container_image has name" "$container_name"
		if [[ -n $(echo $container_image | grep -E "(.*:[a-z0-9].*$)") ]]; then
#			     check if there  is a :tag present ^
			image_tag=":$(echo $container_image | awk -F: '{print $NF}')"
#			  !! Add : ^ before image !! so it is only added to later commands if there is an image at all
			echo -e "$container_image has tag" "$image_tag"
			export container_image=$(echo $container_image | awk -F: '{print $1}')
#			If the container does have a tag, keep the base name   ^ without it (before the :)
			export container_name=$(echo $container_name | awk -F: '{print $1}')
		fi
		echo -e "Fetching local image checksum with:" "docker inspect \"$container_image$image_tag\" | grep -Eo \"($container_image@)?sha256:([0-9a-zA-Z].*)(\\\")\" | sed -e 's/\"//g' | awk -F@ '{print \$2}"
		local_image=$(docker inspect "$container_image$image_tag" | grep -Eo "($container_image@)?sha256:([0-9a-zA-Z].*)(\")" | sed -e 's/"//g' -e 's/\s+//g' | awk -F@ '{print $2}')
#					   remember, this bit ^ is empty without an image             ^ this is the main image checksum remove ^ " and whitespace and^ get the checksum after the @
		if [[ -z $local_image ]]; then
			echo -e "Error fetching local image checksum for container $container_name!"
			#The script will complain about failed containers later on
			echo "container_updated{name=\"$container_name\"} -1" >> $PROM_FILE
			continue 2
		else
			echo -e "Local SHA256 for $container_image is" "$local_image"
		fi
		echo -e "Fetching remote image with:" "skopeo inspect --creds \"$HAKO_USER:$HAKO_PASS\"  docker://docker.io/$container_image$image_tag | grep Digest | head -1 | grep -Eo 'sha256:([0-9a-zA-Z].*)(\")' | sed -e 's/\"//g'"
		#Use Skopeo, a Red Hat tool, with my Docker Hub account to register the remote image checksum
		remote_image=$(skopeo inspect --creds "$HAKO_USER:$HAKO_PASS" docker://docker.io/$container_image$image_tag | grep Digest | head -1 | grep -Eo 'sha256:([0-9a-zA-Z].*)(")' | sed -e 's/"//g' -e 's/\s+//g' )
		#Sometimes; Docker hub hangs up; try again if you failed
		if [[ -z $remote_image ]]; then
			remote_image=$(skopeo inspect --creds "$HAKO_USER:$HAKO_PASS" docker://docker.io/$container_image$image_tag | grep Digest | head -1 | grep -Eo 'sha256:([0-9a-zA-Z].*)(")' | sed -e 's/"//g')
		fi
		#Now, if you still don't have an image after the second try, something's fuckey.
		if [[ -z $remote_image ]]; then
			echo -e "Error fetching remote image checksum for container" "$container_name!"
			echo "container_updated{name=\"$container_name\"} -1" >> $PROM_FILE
			continue 2
		else
			echo -e "Remote SHA256 for $container_image is" "$remote_image"
		fi
		#If we have both checksums, compare them; they should be identical, or the container is outdated.
		if [[ -n $local_image ]] && [[ -n $remote_image ]] && [[ "$local_image" =~ "$remote_image" ]]; then
			echo -e "$container_name" "is up to date!"
		else
			echo -e "$container_name" "is out of date!"
			echo -e "cat \"$container_path/docker-compose.yml\" | grep -B1 \"image: $container_image\" | head -1 | sed -e 's/^[ \t]*//' -e 's/://g' | awk '{print \$NF}')"
			service=$(cat "$container_path/docker-compose.yml" | grep -B1 "image: $container_image" | head -1 | sed -e 's/^[ \t]*//' -e 's/://g' | grep -v 'container_name')
			#	  get container service name (1 line above image) ^		print service name^	    ^ omit tabs and :		and    ^omit container_name
			echo -e "Attempting to update service" "$service"
			if docker compose pull $service; then
				echo -e "Pulled latest image for" "$container_name" 
				if docker compose up -d --remove-orphans; then
					echo -e "$container_stack" "has been updated sucessfully!"
					echo "container_updated{name=\"$container_name\"} 1" >> $PROM_FILE
				else
					echo -e "Failed to update" "$container_name!"
					echo "container_updated{name=\"$container_name\"} 0" >> $PROM_FILE
				fi
			else
				echo -e "Failed to pull image for" "$container_name!"
				echo "container_updated{name=\"$container_name\"} 0" >> $PROM_FILE
			fi
		fi
		#If you found an image tag, reset it before moving on to another container
		image_tag=""
	done
	cd $LOCAL_DIR
done
echo "All done!"

## Once the script finishes, the .prom file will live on for 5 minutes before being deleted.
#+ This allows Prometheus to pick up the alert, send out a notification, and move on with its life.
(
        sleep 300
        rm $PROM_FILE
) 2>1 >/dev/null &
