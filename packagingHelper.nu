#!/usr/bin/env nu

def removePrefix [prefix: string]: string -> string {
  if not ($in | str starts-with $prefix) {
    error make {msg: $"String `($in)` does not have the prefix `($prefix)`"}
  }
  return ($in | str substring ($prefix | str length)..-1)
}

def removeSuffix [suffix: string]: string -> string {
  if not ($in | str ends-with $suffix) {
    error make {msg: $"String `($in)` does not have the suffix `($suffix)`"}
  }
  return ($in | str substring 0..(($in | str length) - ($suffix | str length) - 1))
}

def removeFromEnd (numberToRemove: int): list<any> -> list<any> {
  # TODO: Consider using a more efficient implementation of this
  $in | reverse | skip $numberToRemove | reverse
}

def replaceNull (valueInsteadOfNull: any): any -> any {
  if $in == null {
    $valueInsteadOfNull
  } else {
    $in
  }
}

def getIniValue (valueName: string) {
  let startsWith = $"($valueName) = "
  $in
  | lines
  | where ($it | str starts-with $startsWith)
  | get 0
  | str substring ($startsWith | str length)..-1
}

def getChecksum (filePath: string): any -> string {
  sha256sum $filePath | split row " " | get 0
}

let archPackageRepo = "https://archive.archlinux.org/packages"

def getPackageUrl (packageName: string, packageVersion: string, packageArch: string) {
  return [
    $"($archPackageRepo)/($packageName | split chars | get 0)/($packageName)",
    $"($packageName)-($packageVersion)-($packageArch).pkg.tar.zst",
  ]
}

def downloadPackage (packageName: string, packageVersion: string, packageArch: string) {
  let splitUrl = getPackageUrl $packageName $packageVersion $packageArch
  let url = $splitUrl | str join "/"
  let file = $"/tmp/($packageName)-($packageVersion).tar.zst"
  let dir = $"/tmp/($packageName)-($packageVersion)"

  if not ($dir | path exists) {
    if not ($file | path exists) {
      print $"Fetching ($packageName) from ($url)"
      curl --location $url -o $file
    }

    print $"Extracting ($packageName)"
    mkdir $dir
    tar --extract --use-compress-program unzstd --file $file --directory $dir
  }

  {url: $splitUrl, file: $file, dir: $dir}
}

# TODO: For the places that still ask the user what version of a package to use:
# Use `getLatestPackages` to get the latest version instead of asking the user

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

def main () {
  help main
}

def "main help" () {
  help main
}

def getLibraryDeps [libraryName: string]: any -> list<record> {
  let library = open $"($env.FILE_PWD)/lib/($libraryName).toml"
  if $library.source == "system" {
    let libraryProps = {source: "system"}
    [$libraryProps, {$libraryName: $libraryProps}]
  } else {
    let source = open $"($env.FILE_PWD)/sources/($library.source).toml"
    let libraryProps = {source: $library.source, version: $source.version.main}
    $library
    | get --optional directlyDependentSharedLibraries
    | replaceNull []
    | reduce --fold [$libraryProps, {$libraryName: $libraryProps}] {
      |dependentLibraryName, acc|
      let deps = getLibraryDeps $dependentLibraryName
      [
        ($acc.0 | upsert dependencies ($acc.0 | get --optional dependencies | replaceNull {} | insert $dependentLibraryName $deps.0)),
        ($acc.1 | merge $deps.1),
      ]
    }
  }
}

def getExecutableDeps [sourceName: string, executablePathInSource: string]: any -> list<record> {
  open $"($env.FILE_PWD)/sources/($sourceName).toml"
  | get --optional directlyDependentSharedLibraries
  | get --optional $executablePathInSource
  | replaceNull []
  | reduce --fold [{}, {}] {
    |libraryName, acc|
    let deps = getLibraryDeps $libraryName
    [($acc.0 | insert $libraryName $deps.0), ($acc.1 | merge $deps.1)]
  }
}

def "main getDepsAsList" [--as-nuon (-n), sourceName: string, binaryPathInSource: string] {
  let out = (getExecutableDeps $sourceName $binaryPathInSource).1
  if $as_nuon {
    $out | to nuon
  } else {
    $out
  }
}

def "main getDepsAsTree" [--as-nuon (-n), sourceName: string, binaryPathInSource: string] {
  let out = (getExecutableDeps $sourceName $binaryPathInSource).0
  if $as_nuon {
    $out | to nuon
  } else {
    $out
  }
}

def "main addPackageFromArch" (--arch-agnostic-package, packageName: string, packageVersion: string) {
  let downloadedPackage = downloadPackage $packageName $packageVersion (if $arch_agnostic_package {"any"} else {"x86_64"})

  print "Adding package to sources"
  let pkgInfo = open $"($downloadedPackage.dir)/.PKGINFO"
  {
    homepage: ($pkgInfo | getIniValue url)
    description: ($pkgInfo | getIniValue pkgdesc)
    licenses: [($pkgInfo | getIniValue license)] # TODO: Handle a package having multiple licenses
    urlInMirror: $"($packageName)-${version.main}-(if $arch_agnostic_package {"any"} else {"${architecture}"}).pkg.tar.zst"
    mirrors: [$downloadedPackage.url.0],
    compression: ".tar.zst"
    version: {main: $packageVersion}
    architectureNames: {amd64: "x86_64"}
    checksums: {$downloadedPackage.url.1: (getChecksum $downloadedPackage.file)}
  } | to toml | save $"($env.FILE_PWD)/sources/($packageName).toml"
  main setupSource $packageName

  print "Done"
}

def "main setupSource" (sourceName: string) {
  let tomlFile = $"($env.FILE_PWD)/sources/($sourceName).toml"
  let toml = open $tomlFile
  let sourceDir = ensureSourceIsInstalled $sourceName
  let binariesDir = $"($sourceDir)/usr/bin"
  if ($binariesDir | path exists) {
    let binaries = (
      ls $binariesDir
      | each {|binary| $binary.name | path expand} # This is necersarry to follow symlinks
      | where {|binary| ($binary | path type) == "file"}
      | each {
        |binary|
        return {
          fullPath: $binary,
          pathWithinSource: ($binary | removePrefix $"($env.FILE_PWD)/downloadedSources/($sourceName)/"),
        }
      }
    )
    $binaries | each {
      |binary|
      let binaryName = (basename $binary.fullPath)
      if not ($"($env.FILE_PWD)/bin/($binaryName)" | path exists) {
        main addExecutable $sourceName $binaryName $binary.pathWithinSource
      }
    }
    let binaryDeps = $binaries | where {|binary| (open --raw $binary.fullPath | bytes at 0..3) == 0x[7f 45 4c 46]} | each {
      |binary|
      {libraryPath: $binary.pathWithinSource, deps: (getDirectDeps $binary.fullPath)}
    }
    let newDirectlyDependentSharedLibraries = ($binaryDeps | reduce --fold {} {|dep, acc| $acc | upsert $dep.libraryPath $dep.deps})
    $toml
    | upsert directlyDependentSharedLibraries $newDirectlyDependentSharedLibraries
    | to toml
    | save --force $tomlFile
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
  let contents = {
    source: $sourceName,
    directory: "usr/lib",
    directlyDependentSharedLibraries: (getDirectDeps $libraryPath)
  } | to toml
  $contents | save $path
  print $"Created file ($path) with the following contents:\n($contents)"
}

def getLatestPackages () {
  curl "https://mirrors.edge.kernel.org/archlinux/pool/packages/"
  | lines
  | skip 4
  | removeFromEnd 2
  | each {
    |line|
    $line
      | removePrefix "<a href=\""
      | split row '"'
      | get 0
  } | where {|line| $line | str ends-with ".pkg.tar.zst"}
  | each {
    |fileName|
    let componentsReversed = $fileName
      | removeSuffix ".pkg.tar.zst"
      | str replace --all "%3A" ":"
      | str replace --all "%2B" "+"
      | split row "-"
      | reverse
    let architecture = $componentsReversed | get 0
    let version = $componentsReversed | skip 1 | first 2 | reverse | str join "-"
    let name = $componentsReversed | skip 3 | reverse | str join "-"
    {version: $version, name: $name, architectureAgnostic: (match $architecture {
      "any" => true
      "x86_64" => false
      _ => {error make {msg: $"Unexpected architecture ($architecture) for package ($name)"}}
    })}
  }
}

def "main updatePackages" () {
  let packages = getLatestPackages
  ls sources | each {
    |sourceFile|
    let source = open $sourceFile.name
    if ($source.mirrors.0 | str starts-with "https://archive.archlinux.org") {
    let url = $source.mirrors.0 ++ "/" ++ $source.urlInMirror
      let urlComponents = $url | split row "/"
      let packageName = $urlComponents.5
      let architectureAgnostic = not ("${architecture}" in $url)
      let packageVersions = $packages | where name == $packageName | each {
        |package|
        match [$architectureAgnostic $package.architectureAgnostic] {
          [true false] => {error make {msg: $"The original URL for the ($packageName) package is architecture agnostic, but version ($package.version) of the package is not"}}
          [false true] => {error make {msg: $"The original URL for the ($packageName) package is not architecture agnostic, but version ($package.version) of the package is"}}
          _ => $package.version
        }
      }
      let newVersion = {main: (match ($packageVersions | length) {
        0 => {error make {msg: $"Cannot find the latest version for a package called ($packageName)"}}
        1 => $packageVersions.0
        _ => {
          $packageVersions | input list $"I am not sure what to pick for the latest version of the ($packageName) package. Can you help me select a version"
        }
      })}
      let downloadedPackage = downloadPackage $packageName $newVersion.main (if $architectureAgnostic {"any"} else {"x86_64"})
      let newChecksums = $source.checksums | upsert $downloadedPackage.url.1 (getChecksum $downloadedPackage.file)
      $source
      | update "version" $newVersion
      | update "checksums" $newChecksums
      | save --force $sourceFile.name
    }
  }
}
