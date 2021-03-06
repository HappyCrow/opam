#!/bin/sh -ex
PREFIX=$1
OPAM=$HOME/opam-bin/$PREFIX/bin/opam
ROOT=`echo /x/${JOB_NAME} | sed -e "s,=,_,g" -e "s/,/-/g"`
rm -rf ${ROOT}
$OPAM --yes --root $ROOT init .
$OPAM --yes --root $ROOT remote -add dev git://github.com/mirage/opam-repo-dev
if [ "${compiler}" != "system" ]; then
  $OPAM --yes --root $ROOT switch ${compiler}
fi
if [ "${packages}" = "all" ]; then
  packages=`$OPAM --root $ROOT list -short`
fi
$OPAM --verbose --yes --root $ROOT install ${packages}
