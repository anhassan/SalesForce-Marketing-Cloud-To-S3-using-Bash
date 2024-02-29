echo "SFMC Object Download Script Started........."  
  
# Defining the SFMC Credentails  
SFMC_SERVER="<server_name>.ftp.marketingcloudops.com"  
BASE_DIR="Export/PRD"  
CRED_FILE_NAME="credentials.config"  
  
# Defining the output directory  
OUTPUT_DIR="/apps/nfsload/output"  
  
echo "$CRED_FILE_NAME"  
  
# Defining the user credentails - reading from config file  
source "$CRED_FILE_NAME"  
USER=$SFMC_USER  
PASSWORD=$SFMC_PASSWORD  
  
# Defining the file type for ingestion of data files  
FILE_TYPE=".csv"  
  
# Back Fill Path  
date_today="20240226"  
  
# Default date path - today  
#date_today=$(date '+%Y%m%d')  
  
# Error handling - requirement for the salesforce object to be passed as an input  
num_args=$#  
  
if [ $num_args -lt 1 ]  
then  
echo "Please enter the salesforce object whose files should be copied to the server...."  
exit 1  
fi  
  
object_prefix=$1  
object_name="${object_prefix//_/}"  
  
# Utility function for downloading the data from sfmc using sftp with the provided retries  
download_from_sfmc_sftp(){  
  
# Reading the file level attributes  
file_name=$1  
folder_name=$2  
file_type=$5  
compression=$6  
  
# Reading the user level attributes  
SFMC_USER=$3  
SFMC_PASSWORD=$4  
  
# Reading the operational level attributes  
retries=$7  
allowed_retries=$7  
backoff_step=30  
  
# Default status and progress of the download  
status="FAILED"  
progress=""  
  
  
echo "Starting Download for filename: $file_name..."  
cd $OUTPUT_DIR  
echo "Creating Directory : $folder_name if not exists..."  
mkdir -p $folder_name  
  
output_file_loc=$OUTPUT_DIR/$folder_name/$file_name$file_type  
  
curl_cmnd="\"sftp://$SFMC_SERVER/$BASE_DIR/$file_name$file_type\" --user \"$SFMC_USER:$SFMC_PASSWORD\" -o \"$OUTPUT_DIR/$folder_name/$file_name$file_type\""  
echo $"Curl Command : $curl_cmnd"  
  
iterator=1  
while [ $retries -gt -1 ]; do  
  
# Curl command for downloading the file and output logs - both output and error  
  
curl -k -# "sftp://$SFMC_SERVER/$BASE_DIR/$file_name$file_type" --user "$SFMC_USER:$SFMC_PASSWORD" -o "$OUTPUT_DIR/$folder_name/$file_name$file_type" 2>&1 | tee $OUTPUT_DIR/$folder_name/log_$file_name  
  
log_file=$OUTPUT_DIR/$folder_name/log_$file_name  
echo "LOG FILE LOCATION : $log_file"  
  
# Checking if log file does not exist or is empty  
if [ ! -f $log_file ] && [ ! -s $log_file ];  
then  
echo "Retrying since the curl command for the download did not start properly for File Name : $file_name - Retries Left : $retries"  
retries=$((retries-1))  
else  
# Reading the last line of the log for the final progress of the download  
log_last_line=$(tail -n 1 $log_file)  
progress=$(echo "$log_last_line" | awk '{print $NF}')  
  
# Checking if download started or not  
if [[ $progress == *% ]]  
then  
# Checking if progress got to 100%  
if [[ $progress == "100.0%" ]]  
then  
retries=-1  
status="PASSED"  
echo "Downloaded File Name : $file_name  $progress successfully....."  
# Handling case for incomplete download - Progress < 100%  
else  
echo "Download failed for File Name : $file_name with progress : $progress"  
echo "Retrying the curl command for download for File Name : $file_name - Retries Left : $retries"  
retries=$((retries-1))  
fi  
# Handling the case for when download did not start  
else  
progress=$log_last_line  
echo "Download failed - Error : $progress"  
echo "Retrying the curl command for download for File Name : $file_name - Retries Left : $retries"  
retries=$((retries-1))  
fi  
fi  
  
# Performing exponential back off when retrying  
if [ $retries -gt -1 ];  
then  
backoff_period=$((backoff_step*iterator))  
echo "Waiting for $backoff_period seconds before retrying"  
sleep $backoff_period  
iterator=$((iterator+1))  
fi  
done  
  
# Failing the job if download does not complete after retrying for provided retries  
if [[ $status == "FAILED" ]];  
then  
if [[ $progress == *% ]]  
then  
echo "Download of File Name : $file_name failed after retrying : $allowed_retries times due to incomplete download - Percentage Downloaded : $progress"  
else  
echo "Download of File Name : $file_name failed after retrying : $allowed_retries times with Error : $progress"  
fi  
exit 1  
fi  
  
# Compressing the file to .gz if its is a data file - for data compression == "Y"  
if [[ $compression == "Y" ]];  
then  
echo "Zipping Data File - File Name : $file_name"  
cd $folder_name  
gzip -f $file_name$file_type  
else  
echo "No Zipping required for Audit File - File Name : $file_name "  
fi  
  
}  
  
# Identifying whether the object is log object or data object  
if [[ $object_name == *Log ]]  
then  
# providing today date or backfilled date for the audit file  
file_name="$object_prefix$date_today"  
  
# downloading the audit file - no file type , compression == "N" (not required) and retries = 3  
echo "Getting Started to download a Log file - File Name : $file_name"  
download_from_sfmc_sftp $file_name $object_name $USER $PASSWORD "" "N" 3  
else  
# providing today date -1 or backfilled date -1 for the data file  
date_yesterday=$(date -d "$date_today -1 days" +"%Y%m%d")  
file_name="$object_prefix"_"$date_yesterday"  
  
# downloading the data file - given file type and compression == "Y" (required) and retries = 3  
echo "Getting Started to download a Data file - File Name : $file_name"  
download_from_sfmc_sftp $file_name $object_name $USER $PASSWORD $FILE_TYPE "Y" 3  
  
fi
