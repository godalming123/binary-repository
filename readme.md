# Binary repository

A repository of binaries from other build systems that is designed to be used with [exec-bin](https://github.com/godalming123/exec-bin).

## Packaging binaries

```sh
BINARY_NAME=ghostty
SOURCE_NAME=ghostty
PATH_IN_SOURCE=bin
ln -sr sources/$SOURCE_NAME/$PATH_IN_SOURCE bin/$BINARY_NAME
```
