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

def ensureSourceIsInstalled (sourceName: string) {
  let sourceDir = $"($env.FILE_PWD)/downloadedSources/($sourceName)"
  if not ($sourceDir | path exists) {
    # Ensure that the source is setup
    if not ($"($env.FILE_PWD)/sources/($sourceName).toml" | path exists) {
      let version = (input $"Enter the version of the source ($sourceName): ")
      main addPackageFromArch $sourceName $version
    }

    # Ensure that the source is fetched
    do --ignore-errors {bento exec $sourceName - -}
  }
  return $sourceDir
}

def getDirectDeps [binaryPath: string]: any -> list<string> {
  return (
    readelf -d $binaryPath
    | parse --regex '\(NEEDED\) [^\n]* \[(?P<deps>.*)\]'
    | get deps
  )
}

def formatTomlList (items: list<string>): any -> string {
  return (if ($items | length) == 0 { "[]" } else {
    $"[\n($items | each {|item| $'  "($item)",'} | str join "\n")\n]"
  })
}

def main () {
  help main
}

def "main addPackageFromArch" (--arch-agnostic-package, packageName: string, packageVersion: string) {
  let url = getPackageUrl $packageName $packageVersion (if $arch_agnostic_package {"any"} else {"x86_64"})
  let file = $"/tmp/($packageName).tar.zst"
  let dir = $"/tmp/($packageName)"

  if not ($dir | path exists) {
    if not ($file | path exists) {
      print $"Fetching ($packageName) from ($url)"
      curl --location $url -o $file
    }

    print $"Extracting ($packageName)"
    mkdir $dir
    tar --extract --use-compress-program unzstd --file $file --directory $dir
  }

  print "Adding package to sources"
  let pkgInfo = open $"($dir)/.PKGINFO"
  [
    $"homepage = \"($pkgInfo | getIniValue url)\""
    $"description = \"($pkgInfo | getIniValue pkgdesc)\""
    $"licenses = [\"($pkgInfo | getIniValue license)\"]" # TODO: Hanlde a package having multiple licenses
    $"url = \"(getPackageUrl $packageName "${version.main}" (if $arch_agnostic_package {"any"} else {"${architecture}"}))\""
    "compression = \".tar.zst\""
    $"version.main = \"($packageVersion)\""
    "architectureNames.amd64 = \"x86_64\""
    ""
    "[checksums]"
    $'"($url)" = "(sha256sum $file | split column " " | get column1.0)"'
    ""
  ] | str join "\n" | save $"($env.FILE_PWD)/sources/($packageName).toml"
  main setupSource $packageName

  print "Done"
}

def "main setupSource" (sourceName: string) {
  let tomlFile = $"($env.FILE_PWD)/sources/($sourceName).toml"
  let sourceDir = ensureSourceIsInstalled $sourceName
  let binariesDir = $"($sourceDir)/usr/bin"
  if ($binariesDir | path exists) {
    let binaries = ls $binariesDir | where {|binary| (open --raw $binary.name | bytes at 0..3) == 0x[7f 45 4c 46]} | each {
      |binary|
      print $binary.name
      let deps = getDirectDeps $binary.name
      # TODO: Fix the path $binary.name so that it is relative to $binariesDir
      return $'"($binary.name)" = (formatTomlList $deps)'
    }
    if ($binaries | length) > 0 {
      [
        ""
        "[directlyDependentSharedLibraries]"
        ...$binaries
      ] | str join "\n" | save --append $tomlFile
    }
  }
  # TODO: Handle setting up the shared libraries as well as the binaries
}

def "main addExecutable" (sourceName: string, executableName: string, executablePathInSource: string) {
  ensureSourceIsInstalled $sourceName
  let path = $"($env.FILE_PWD)/bin/($executableName)"
  $"#!/usr/bin/env -S bento exec ($sourceName) ($executablePathInSource)\n" | save $path
  chmod +x $path
  print $"Created executable ($path)"
}

def "main addLibrary" (sourceName: string, libraryName: string) {
  ensureSourceIsInstalled $sourceName
  let path = $"($env.FILE_PWD)/lib/($libraryName).toml"
  let libraryPath = $"($env.FILE_PWD)/downloadedSources/($sourceName)/usr/lib/($libraryName)"
  let contents = [
    $'source = "($sourceName)"'
    'directory = "usr/lib"'
    $"directlyDependentSharedLibraries = (formatTomlList (getDirectDeps $libraryPath))"
  ] | str join "\n"
  $contents | save $path
  print $"Created file ($path) with the following contents:\n($contents)"
}
