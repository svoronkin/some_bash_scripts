#!/bin/bash
# verify file checksum from a file

# checksum algorithms
algorithms=( 1 224 256 384 512 512224 512256 )

# file to check
file="$1"

# execute when there is one parameter
if [ "$#" -eq "1" ]; then
  # check if file exist
  if [ -f "${file}" ]; then
    # find checksum file
    for algorithm in "${algorithms[@]}"; do
      if [ -f "${file}.sha${algorithm}" ]; then
        echo "Found SHA${algorithm} checksum"
        words="$(wc -w < ${file}.sha${algorithm})"
        # verify checksum and pass the exit code
        if [ "$words" == "1" ]; then
          shasum --algorithm $algorithm --check <(echo $(cat ${file}.sha${algorithm})\ \ $file)
          exit $?
        elif [ "$words" == "2" ] || [ "$words" == "4" ]; then
          shasum --algorithm $algorithm --check ${file}.sha${algorithm}
          exit $?
        fi
      fi
    done
  fi
fi
