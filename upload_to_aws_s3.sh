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
