#!/bin/bash
#Check Federated Cloud Image Management and BDII Information System processes
#
#This probe will check the full end-to-end image management process and the
#dynamic data gathering functionalities of the site BDII. In particular, it
#will verify that images from a given vmcatcher image list are correctly
#displayed into the BDII. Since the BDII gathers the image list information
#directly from the cloud middleware, if this image list is the same as the one
#in the original vmcatcher image list we can suppose that the cloud middleware
#correctly registered all the image list images.
#
#Author: Salvatore Pinto (salvatore.pinto@egi.eu)

function do_critical {
  echo "IMBDII CRITICAL: $1"
  exit 2
}

function do_warning {
  echo "IMBDII WARNING: $1"
  exit 1
}

function do_error {
  echo "IMBDII ERROR: $1"
  exit 3
}

function do_ok {
  echo "IMBDII OK"
  exit 0
}

function debuglog {
  $_DEBUG && echo "IMBDII DEBUG: $*"
}

function usage {
  [[ -n "$1" ]] && echo "IMBDII ERROR: $1"
  echo "Check Image Management and BDII Information System Nagios plugin

Usage: ${0##*/} [options] -H <site-name>

Where <site-name> is the BDII site name (GLUE2GroupID).

Options are:
  -T <topbdii>  Set top-bdii to be used. Default is $_BDII
  -l <imglist>  Image list to verify. Default is $_IMGLIST
  -C <list>     Custom list of metadata to check between the image list
                and the BDII. Should contain a comma separated list of
                <bdii_attribute>=#<vmcatcher_image_list_property># elements.
                Default value is $_CHKLIST
  -b <base>     Define a base BDII DN for the cloud resources. Default is
                $_BDII_BASE
  -j <obj>      Define the name of the BDII class representing an OS image
                resources. Default is $_BDII_IMOBJECT
  -d            Display debug information
"
  exit 1
}

_SITE=
_BDII="ldap://lcg-bdii.cern.ch:2170"
_BDII_BASE="GLUE2GroupID=cloud,GLUE2DomainID=#site-name#,GLUE2GroupID=grid,o=glue"
_BDII_IMOBJECT="GLUE2ApplicationEnvironment"
_IMGLIST="https://vmcaster.appdb.egi.eu/store/vo/fedcloud.egi.eu/image.list"
_CHKLIST="GLUE2ApplicationEnvironmentRepository=#ad:mpuri#"
_DEBUG=false

#Parse arguments
while [[ "$#" -gt 0 ]]; do
  case "$1" in
   -H) _SITE="$2"; shift 2 ;;
   -T) _BDII="$2"; shift 2 ;;
   -l) _IMGLIST="$2"; shift 2 ;;
   -b) _BDII_BASE="$2"; shift 2 ;;
   -d) _DEBUG=true; shift 1 ;;
   -h | --help) usage ;;
   *) do_error "Unnknown option: $1"
    ;;
  esac
done

#Check mandatory attributes
[[ -z "$_SITE" ]] && usage "Missing site-name parameter. See usage."

#Check required software
LDAPSEARCH="`which ldapsearch 2>/dev/null`"
[[ $? -ne 0 ]] && do_error "Missing ldapsearch command. This is required by this script"
CURL="`which curl 2>/dev/null`"
[[ $? -ne 0 ]] && do_error "Missing curl command. This is required by this script"
GAWK="`which gawk 2>/dev/null`"
[[ $? -ne 0 ]] && do_error "Missing gawk command. This is required by this script"

debuglog "Getting images info from the image list..."
T=`curl -s -k "$_IMGLIST" | gawk -v CL="$_CHKLIST" 'BEGIN{FS="\"";RS=",|{"}{if($2=="hv:image"){i=1;delete d};if($2!=""&&$4!=""){d[$2]=$4}if($0~"}"&&(i==1)){i=0;val=CL;for(a in d){gsub("#"a"#",d[a],val)};printf val"|"}}'`
res="${PIPESTATUS[0]}"
[[ $res -ne 0 ]] && do_warning "Failed to access the image list. Is the image list server down?"
[[ -z "$T" || "$T" == '|' ]] && do_warning "Image list is empty, unaccessible or we failed to parse it. Please check curl -s -k $_IMGLIST"

debuglog "Looking for images in the LDAP..."
base="`gawk -v S="$_SITE" '{gsub("#site-name#",S,$0);print $0}' <<<"$_BDII_BASE"`"
nok_list=""
ok=0
nok=0
IFS=$'|'
for im in $T; do
  [[ -z "$im" ]] && continue
  debuglog "Looking for image with base $base and attributes $im"

  #Build LDAP filter
  LDAPFILTER="(&(objectClass=$_BDII_IMOBJECT)"
  for fl in ${im//,/|}; do
    LDAPFILTER="$LDAPFILTER($fl)"
  done
  LDAPFILTER="$LDAPFILTER)"

  #Execute LDAP query
  debuglog "Executing ldapsearch -x -H $_BDII -b \"$base\" \"$LDAPFILTER\""
  imgs=`ldapsearch -x -H $_BDII -b "$base" "$LDAPFILTER" | gawk 'BEGIN{FS=":"}{gsub(" ","",$0);if($1=="#numEntries")print $2}'`
  res="${PIPESTATUS[0]}"
  [[ $res -ne 0 ]] && do_warning "Failed to contact the LDAP server. Is the top BDII down?"

  if [[ -n "$imgs" && "$imgs" -gt 1 ]]; then
    debuglog "Image $im seems to be published correctly on $base"
    ok=$(( $ok + 1 ))
  else
    debuglog "Image $im seems missing on $base"
    nok=$(( $nok + 1 ))
    nok_list="$nok_list,$im"
  fi
done
unset IFS

if [[ $ok -gt 0 && $nok -eq 0 ]]; then
  do_ok
else
  do_critical "$nok images on $(( $ok + $nok )) are not correctly updated (Missing attributes: ${nok_list#,})"
fi
