#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset
set -o posix

unset DESTDIR #TODO: handle DESTDIR set by the caller

function usage {
cat <<EOF
Build and install script for Open Hexagon and dependencies.
Parameters:
	<Installation prefix>
		The first argument that is not a valid option will be treated
		as the install prefix path. It may appear only once. If not
		specified, "$prefixDirDefault" will be used.
		The actual files will be installed into the $projectName
		subdirectory. The contents of that subdirectory will be erased.
	-c, --clean
		Delete the build directories and make everything from scratch.
	-d, --install-dependencies
		Install the dependencies of this project ("make install").
		If this option is not specified, the dependencies will be used
		from their (temporary) build directories.
	-g, --debug
		Build with debug symbols and do not strip resulting binary.
	-j <N>
		Use <N> build jobs instead of the default of $makeJobs.
	-r, --standalone
		Standalone mode: do not bake RPATH into binary on install.
	-s, --use-sudo
		Call installation commands (such as "make install") with sudo.
		Note that without password caching you might have to type your
		password quite a few times!
	-v, --verbose
		Show commands before executing them ("set -o xtrace").
	-y, --yes-to-all
		Answer "yes" to all questions instead of prompting the user.
		Note that if using "-s", sudo will still prompt for password.
	--help
		Display this help message and exit.

Arguments may be given in any order.
EOF
}

function onExit {
	[ $? -eq 0 ] || echo -e "\nScript finished unsuccessfully." 1>&2
}

function die {
	local msg="$1"
	local code="${2:-1}"
	echo "$msg" 1>&2
	exit "$code"
}

function askContinue {
	[ "$flagYesToAll" = false ] || return 0
	read -p "Continue? [Y/n] "
	! [[ "$REPLY" =~ ^[nN]$ ]] || die
}

function run {
	set +e
	RUN_OUTPUT="$(set -e ; "$@")"
	RUN_STATUS=$?
	set -e
}

function listSoDeps {
	ldd "$1" | grep -v 'linux-vdso.so' |
		sed -rn 's/^\t(.+ => )?(.+) \(0x.+\)$/\2/p'
	#TODO: OSX support
}

function absPath {
	local relPath="$1"
	[ -e "$relPath" ] || return 1
	if [ -d "$relPath" ]; then
		cd "$relPath"
		echo "$PWD"
		cd "$OLDPWD"
	else
		local relDir="$(dirname -- "$relPath")"
		local relFile="$(basename -- "$relPath")"

		cd "$relDir"
		echo "$PWD/$relFile"
		cd "$OLDPWD"
	fi
}

trap onExit EXIT

GLOBIGNORE="${GLOBIGNORE:-.:..}" #this also makes .* visible in *

case "$OSTYPE" in
	*linux*)
		alias xargs='xargs -r'
		soDepsToolName=ldd
		;;
	*bsd*)
		soDepsToolName=ldd
		;;
	*darwin*)
		die "OSX is not supported yet." #TODO
		soDepsToolName=otool
		;;
esac

projectName="SSVOpenHexagon"
binName="SSVOpenHexagon"
bootstrapName="OpenHexagon"
flagClean=false
flagInstallDeps=false
flagStandalone=false
flagYesToAll=false
buildType="Release"
do=""
makeJobs=2
prefixDir=""
prefixDirDefault="/usr/local/games"

while [ $# -ne 0 ]; do
	case "$1" in
		-c|--clean)                flagClean=true       ;;
		-d|--install-dependencies) flagInstallDeps=true ;;
		-g|--debug)                buildType="Debug"    ;;
		-r|--standalone)           flagStandalone=true  ;;
		-s|--use-sudo)             do=sudo              ;;
		-v|--verbose)              set -o xtrace        ;;
		-y|--yes-to-all)           flagYesToAll=true    ;;
		--help)                    usage; exit 0        ;;
		-j*)
			makeJobs="${1:2}"
			if [ -z "$makeJobs" ]; then
				makeJobs="$2"
				shift
			fi
			[[ "$makeJobs" =~ ^[1-9][0-9]*$ ]] || { usage; die; }
			;;
		*)
			[ -z "$prefixDir" ] || { usage; die; }
			prefixDir="$1"
			;;
	esac
	shift
done
prefixDir="${prefixDir:-"$prefixDirDefault"}"

run absPath "$prefixDir"
prefixDirAbs="$RUN_OUTPUT"
if [ $RUN_STATUS -ne 0 ]; then
	if ! [ "$flagYesToAll" = true ]; then
		read -p "$prefixDir does not exist. Create it? [Y/n] "
		! [[ "$REPLY" =~ ^[nN]$ ]] || die "Cannot continue."
	fi

	mkdir -p "$prefixDir"
	prefixDirAbs="$(absPath "$prefixDir")"
fi

[ -d "$prefixDirAbs" ] || die "$prefixDir is not a directory."
$do [ -w "$prefixDirAbs" ] || die "Write permission denied on $prefixDir."

repoReleaseSubdir="$(absPath ./_RELEASE)"
if [ "${prefixDirAbs##"$repoReleaseSubdir"}" != "$prefixDirAbs" ]; then
	die "Do not install into the _RELEASE subdir of your repo."
fi

destinationDir="$prefixDirAbs/$projectName"
cmakeFlags=("-DCMAKE_BUILD_TYPE=$buildType"
	"-DCMAKE_INSTALL_PREFIX=$destinationDir")

if [ "$flagStandalone" = true ]; then
	cmakeFlags+=("-DCMAKE_SKIP_BUILD_RPATH=True")
fi

echo "Build and installation of $projectName will start with these options:"
echo "Build Type:            $buildType"
echo "Build Jobs:            $makeJobs"
echo "Destination Directory: $destinationDir"
echo "Initial CMake Flags:   ${cmakeFlags[@]}"

if [ "$flagStandalone" = true ]; then
	echo "Standalone mode active: RPATH will NOT be baked into binaries."
	echo "Needed libraries will be copied next to the output binary."
	echo "$soDepsToolName needs to be present."
else
	echo "Standalone mode NOT active: RPATH will be baked into binaries."
fi

if [ "$flagInstallDeps" = true ]; then
	echo "Dependencies (SSV libraries) will be installed."
else
	echo "Dependencies (SSV libraries) will be compiled in a temp dir."
fi

echo
echo "A C++14 capable compiler is required."
echo "The contents of $destinationDir WILL BE DELETED (if any)."
echo
askContinue

if [ -e "$destinationDir" ]; then
	find "$destinationDir" -mindepth 1 -print0 | xargs -0 $do rm -rf
else
	$do mkdir -p "$destinationDir"
fi

# List of extlibs to build in order
dependencies=(
	"vrm_pp"
	"SSVUtils"
	"SSVMenuSystem"
	"SSVEntitySystem"
	"SSVLuaWrapper"
	"SSVStart"
)

dependenciesIncludeDirs=()

function buildLib {
	local libName="$1"

	echo "Building $libName..."

	cd "$libName"
	[ "$flagClean" = false ] || ! [ -e build ] || rm -rf build
	[ -d build ] || mkdir build
	cd build

	cmake .. "${cmakeFlags[@]}"
	make "-j$makeJobs"

	if [ "$flagInstallDeps" == true ]; then
		$do make install "-j$makeJobs"
	else
		cd ..
		dependenciesIncludeDirs+=("$PWD")
		echo "Added $PWD to dependencies include directories."

		cd ./include
		dependenciesIncludeDirs+=("$PWD")
		echo "Added $PWD to dependencies include directories."
	fi

	cd ../.. # Back to extlibs
	echo "Finished building $libName."
}

cd extlibs
for lib in "${dependencies[@]}"; do
	buildLib "$lib"
done
cd ..

echo
echo "Building $projectName..."
[ "$flagClean" = false ] || ! [ -e build ] || rm -rf build
[ -d build ] || mkdir build
cd build

if [ "$flagInstallDeps" = false ]; then
	echo "Setting additional CMake flags..."
	flag="-DCMAKE_INCLUDE_PATH="
	for dir in "${dependenciesIncludeDirs[@]}"; do
		flag+="$dir:"
	done
	cmakeFlags+=("$flag")

	echo "Final CMake Flags:"
	echo "${cmakeFlags[@]}"
	echo
	askContinue
fi

cmake .. "${cmakeFlags[@]}"
make "-j$makeJobs"
$do make install "-j$makeJobs"

cd ..
echo "Finished building $projectName."

if [ "$buildType" = Release ]; then
	find "$destinationDir" -name 'SSV*.so' -print0 | xargs -0 strip -s
	find "$destinationDir" -name 'SSV*.so' -print0 | xargs -0 upx -9

	strip -s "$destinationDir/$binName"
	upx -9 "$destinationDir/$binName"
fi

if [ "$flagStandalone" = true ]; then
	echo "Copying system libraries..."

	libDestDir="$destinationDir/lib"
	[ -e "$libDestDir" ] || $do mkdir "$libDestDir"

	listSoDeps "$destinationDir/$binName" | while read libPath; do
		libName="$(basename "$libPath")"
		$do cp "$libPath" "$libDestDir/$libName"
	done

	cat >"$destinationDir/$bootstrapName" <<-EOF
	#!/bin/bash
	set -o errexit
	$(declare -f absPath)
	myPath="\$(absPath "\$(dirname -- "\${BASH_SOURCE[0]}")")"
	export LD_LIBRARY_PATH="\$myPath/lib:\$LD_LIBRARY_PATH"
	cd "\$myPath"
	./SSVOpenHexagon
	EOF

	chmod +x "$destinationDir/$bootstrapName"
fi

$do cp -Rv "$repoReleaseSubdir/" "$destinationDir"

echo "Successfully finished building $projectName."
