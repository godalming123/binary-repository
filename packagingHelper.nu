#!/usr/bin/env nu

def getIniValue (valueName: string) {
  let startsWith = $"($valueName) = "
  $in
  | lines
  | where ($it | str starts-with $startsWith)
  | get 0
  | str substring ($startsWith | str length)..-1
}

def getPackageUrl (packageName: string, packageVersion: string, packageArch: string) {
  $"https://archive.archlinux.org/packages/($packageName | split chars | get 0)/($packageName)/($packageName)-($packageVersion)-($packageArch).pkg.tar.zst"
}

def main () {
  print "Please specify a subcommand"
}

def "main addPackageFromArch" (--arch-agnostic-package, packageName: string, packageVersion: string) {
  let url = getPackageUrl $packageName $packageVersion (if $arch_agnostic_package {"any"} else {"x86_64"})
  let file = $"/tmp/($packageName).tar.zst"
  let dir = $"/tmp/($packageName)"

  print $"Fetching ($packageName) from ($url)"
  curl --location $url -o $file

  print $"Extracting ($packageName)"
  mkdir $dir
  tar --extract --use-compress-program unzstd --file $file --directory $dir

  print "Adding package to sources"
  let pkgInfo = open $"($dir)/.PKGINFO"
  [
    $"homepage = \"($pkgInfo | getIniValue url)\""
    $"url = \"(getPackageUrl $packageName "${version.main}" (if $arch_agnostic_package {"any"} else {"${architecture}"}))\""
    "compression = \".tar.zst\""
    $"version.main = \"($packageVersion)\""
    "architectureNames.amd64 = \"x86_64\""
    ""
  ] | str join "\n" | save $"($env.FILE_PWD)/sources/($packageName).toml"

  print "Done"
}

def "main addExecutable" (sourceName: string, executableName: string, executablePathInSource: string) {
  let path = $"($env.FILE_PWD)/bin/($executableName)"
  $"#!/usr/bin/env -S bento exec ($sourceName) ($executablePathInSource)\n" | save $path
  chmod +x $path
  print $"Created executable ($path)"
}

def "main addLibrary" (sourceName: string, libraryName: string) {
  let path = $"($env.FILE_PWD)/lib/($libraryName).toml"
  let libraryPath = $"($env.FILE_PWD)/downloadedSources/($sourceName)/usr/lib/($libraryName)"
  if not ($libraryPath | path exists) {
    # Ensure that the source is setup
    if not ($"($env.FILE_PWD)/sources/($sourceName).toml" | path exists) {
      let version = (input $"Enter the version of the source ($sourceName): ")
      main addPackageFromArch $sourceName $version
    }

    # Ensure that the source is fetched
    do --ignore-errors {bento exec $sourceName - -}
  }
  let libraryDirectDepsFormatted = readelf -d $libraryPath
    | parse --regex '\(NEEDED\) [^\n]* \[(?P<names>.*)\]'
    | get names
    | each {|name| $'  "($name)",'}
  let contents = [
    $'source = "($sourceName)"'
    'directory = "usr/lib"'
    $"directlyDependentSharedLibraries = (if ($libraryDirectDepsFormatted | length) == 0 {"[]"} else {
      $"[\n($libraryDirectDepsFormatted | str join "\n")\n]"
    })"
  ] | str join "\n"
  $contents | save $path
  print $"Created file ($path) with the following contents:\n($contents)"
}
