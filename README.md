# Introduction
This Article talks about a generic ETL written in UNIX server in BASH which pulls data from Salesforce Marketing Cloud using SFTP, stages it in UNIX server and writes it to S3 Bucket - Data Lake ingestion layer.
To spice things up lets create a hypothetical use case inspired from a ingestion data pattern that I created recently at my workplace.
Suppose, everyday two types of files get created in the Salesforce Marketing Cloud. These are as follows:
1. **Data Files** : Every day we get these files for current day - 1 and they are in CSV format. Not all the files are in the ideal CSV format therefore CSV has to be massaged into ideal ; delimited format before but that is a topic for another day and therefore would be discussed later. To understand better on 2024-02-02 we would get file for 2024-02-01 (current day -1). The naming format for these data files is as follows: `<object_name>_<current_day-1>.csv` for instance `account_20240201.csv`

2. **Audit Files**: Every day we get these files for current day - 1 and they are in binary format. For instance, on 2024-02-02 we would get file for 2024-02-02 (current day). The naming format for these files is as follows two types : `<object_name><current_day>` for instance `log20240202.csv` and `<object_name>_<current_day>` for instance `auditlog_20240202`

The requirements are as follows:

1. The Salesforce Marketing Cloud (SFMC) server can only be accessed using SFTP protocol
2. In case of failure of download of data - includes both scenarios:  no download and incomplete download, the process should be retried for given number of retry attempts, for instance 3 
3. To ensure complete download we cannot measure file size on the SFMC server therefore we have to parse the CURL logs during download
4. The download path should be in the format : `<OUTPUT_DIR>\<object_name>\<object_file>` for instance `\apps\nfsload\output\account\account_20240201.csv.gz`
5. The data files should be compressed in `.gz` format so that they occupy less space
6. In case of failure of upload the process should be retried for given number of retry attempts, for instance 3 
7. Before upload, the current timestamp should be added in the object folder name and object file name in the format YYYY-MM-DDTHH:MM:SS for backtracking purposes therefore the upload file path format should be `s3://<bucket_name>/<folder_name>/<object_name-YYYY-MM-DDTHH:MM:SS>/<object_file.csv.gz-YYYY-MM-DDTHH:MM:SS>` for instance `s3://appsbucket/ingestion/sfmc/objects/account-2024-02-01T12:02:34/account.csv.gz-2024-02-01T12:02:34`
8. After the upload process, the files should be moved to archive folder so that they are not processed again 
9. The retries should be exponential, every subsequent retry should be made after longer amount of time than the first. For instance, if the first retry is made after 30 seconds then the second retry should be made after 60 and third retry should be made after 90 seconds and so on and so forth
10. The solution should also accommodate backfilling - the process of filling in missing data from the past

# Design and Implementation
To achieve the above, we would require two scripts:
1. `download_from_sfmc.sh` : To download files from SFMC server to UNIX server according to the above conditions
2. `upload_to_aws_s3.sh` : To download files from UNIX server to AWS S3 according to the above conditions

Let's design and implement both of them

The `download_from_sfmc.sh` script does the following:

1.  It requires an SFMC input object name as a command line argument
2.  If the command line argument is not provided, it errors out and asks the user for it (input error handling)
3.  Given the object name, it identifies whether the object is data object or audit object (assumption: audit object name ends with Log)
4.  For the data object it downloads the object for current day - 1 or provided backfill day - 1 and compresses the data file into .gz format (data file for a particular object contains the date in the name of the file)
5.  For the audit object , the script downloads the object for current day or provided backfill day (audit file for a particular object contains the date in the name of the file)
6.  For error handling the script accepts retries and they work in the following way:  
    a. Upon failure, the script retries for the provided number of allowed retries - the retries are based on exponential backoff, after every failure the time after which the retry occurs is increased by 30 sec * number of retry attempt  
    b. if after the provided number of retries, the object is not downloaded the script errors out telling whether the last retry failed because of partial download (% download mentioned in the error) or either because the download never got started due network congestion/issues etc
7.  For better security, the username and password for the SFMC user is read from a separate config file in the script and therefore the values are not hardcoded

```bash
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
```

The `upload_to_aws_s3.sh` script does the following:

1.  It requires an SFMC input object name as a command line argument
2.  If the command line argument is not provided, it errors out and asks the user for it (input error handling)
3.  Given the object name, it identifies whether the object is data object or audit object (assumption: audit object name ends with Log)
4.  For the data object it uploads the object for current day - 1 or provided backfill day - 1 (data file for a particular object contains the date in the name of the file)
5.  For the audit object , the script downloads the object for current day or provided backfill day (audit file for a particular object contains the date in the name of the file)
6.  Before upload, it appends the current timestamp in the object folder name and object file name in the format YYYY-MM-DDTHH:MM:SS for backtracking purposes
7.  After uploading the file, it creates an archive in the object directory if not created and moves the file to the archival folder so that does not get processed again
8.  For error handling the script accepts retries and they work in the following way:  
    a. Upon failure, the script retries for the provided number of allowed retries - the retries are based on exponential backoff, after every failure the time after which the retry occurs is increased by 30 sec * number of retry attempt  
    b. if after the provided number of retries, the object is not uploaded the script errors out telling whether the last retry failed after retrying for the given number of retries

```bash
echo "SFMC Object Upload Script Started........."  
  
# Defining the source and destination credentials for file upload to S3  
INPUT_DIR="/apps/nfsload/output"  
S3_BUCKET_NAME="edl-ingestion-prd"  
S3_OBJ_PREFIX="ingestion/salesforceMarketingClould/objects"  
DESTINATION_S3_BASE="s3://$S3_BUCKET_NAME/$S3_OBJ_PREFIX"  
ENV="prd"  
  
# Defining the file type for ingestion of data files  
FILE_TYPE=".csv.gz"  
  
# Back Fill Path  
date_today="20240226"  
  
# Default date path - today  
#date_today=$(date '+%Y%m%d')  
  
# Getting the number of arguments passed from command line  
num_args=$#  
  
# Error handling - requirement for the salesforce object to be passed as an input  
if [ $num_args -lt 1 ];  
then  
echo "Please provide the object which should be uploaded to S3..."  
exit 1  
fi  
  
object_prefix=$1  
object_name="${object_prefix//_/}"  
  
# Utility function for uploading object file from unix server to s3 with provided retries  
# and archiving the file after upload to archive folder  
upload_to_s3_archive(){  
  
# Reading the file level attributes  
source_file_path=$1  
dest_path=$2  
file_type=$4  
  
# Reading the operational level attributes  
allowed_retries=$3  
retries=$3  
backoff_step=30  
  
# Default status and progress of the download  
status="FAILED"  
  
bucket_name=$S3_BUCKET_NAME  
key_prefix=$S3_OBJ_PREFIX  
  
# Checking whether the provided source file exists or not  
if [ ! -f $source_file ];  
then  
echo "Source File provided - File Path : $source_file does not exist..."  
exit 1  
fi  
  
# Adding current timestamp to the destination filename  
now=$(date +"%Y-%m-%dT%H:%M:%S")  
dest_file_path=$dest_path/$now/$object_name-$now$file_type  
  
iterator=1  
while [[ $retries -gt -1 ]]; do  
  
# uploading the file to s3  
~/.local/bin/aws s3 cp $source_file_path $dest_file_path --profile $ENV  
# checking whether the file got uploaded to s3 or not  
~/.local/bin/aws s3api head-object --bucket $bucket_name --key $key_prefix/$object_name/$now/$object_name-$now$file_type --profile $ENV > status.json  
# checking the content length of file uploaded - if content length <= 0, then file did not get uploaded  
content_length=$(cat status.json | grep "ContentLength" | grep -o -E '[0-9]+')  
rm -rf status.json  
  
# Retrying the upload process if file did not get uploaded  
if [[ $content_length -gt 1 ]];  
then  
echo " SUCCESS - Object : $object_name with Source File Path : $source_file_path successfully uploaded to S3 File path : $dest_file_path"  
retries=-1  
status="PASSED"  
else  
echo "FAILURE - Object : $object_name with Source File Path : $source_file_path failed to upload to S3 File path : $dest_file_path"  
echo "Retrying Upload - Retries Left : $retries"  
retries=$((retries-1))  
  
fi  
  
# Performing exponential back off when retrying  
if [[ $retries -gt -1 ]];  
then  
backoff_period=$((backoff_step*iterator))  
echo "Waiting for $backoff_period seconds before retrying"  
sleep $backoff_period  
iterator=$((iterator+1))  
fi  
  
done  
  
# Failing the job if upload does not complete after retrying for provided retries  
if [[ $status == "FAILED" ]];  
then  
echo "FAILURE - Upload of Object : $object_name with Source File Path : $source_file_path failed to upload to S3 File path : $dest_file_path after retrying $allowed_retries times"  
exit 1  
else  
# archiving the file to archive folder  
archive_folder=$INPUT_DIR/$object_name/archive  
# Create archive folder for the object if not created before  
mkdir -p $archive_folder  
# Moving uploaded file from object folder to archive folder  
echo "Moving the Source File Name with Source File Path : $source_file_path to Archive folder"  
mv $source_file_path $archive_folder  
fi  
  
}  
  
  
# Identifying whether the object is log object or data object  
if [[ $object_name == *Log ]];  
then  
# providing today date or backfilled date for the audit file  
file_name=$object_prefix$date_today  
  
# defining the source and destination file paths for upload  
source_file=$INPUT_DIR/$object_name/$file_name  
dest_path=$DESTINATION_S3_BASE/$object_prefix  
  
# uploading the audit file to the required S3 bucket  
upload_to_s3_archive $source_file $dest_path 3 ""  
else  
# providing today date -1 or backfilled date -1 for the data file  
date_yesterday=$(date -d "$date_today -1 days" +"%Y%m%d")  
file_name=$object_prefix"_"$date_yesterday  
  
# defining the source and destination file paths for upload  
source_file=$INPUT_DIR/$object_name/$file_name$FILE_TYPE  
dest_path=$DESTINATION_S3_BASE/$object_prefix  
  
# uploading the data file to the required S3 bucket  
upload_to_s3_archive $source_file $dest_path 3 $FILE_TYPE  
fi
```

The architecture diagram below would make the understanding of the entire solution more crisp

<p align="center">
  <img src="/assets/scd_mismatch_results.png" />
</p>
