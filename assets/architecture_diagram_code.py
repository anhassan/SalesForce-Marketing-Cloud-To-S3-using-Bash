from diagrams import Diagram,Cluster
from diagrams.programming.language import Bash
from diagrams.aws.storage import S3
from diagrams.custom import Custom

graph_attr = {
    "fontsize": "20",
    "bgcolor": "transparent"
}

with Diagram("Sales Force Marketing Cloud (SFMC) To UNIX Server To S3 ETL",
             show=False,graph_attr=graph_attr):

  sfmc_server = Custom("Sfmc Server", "salesforce-marketing-cloud-seeklogo.png")

  with Cluster("UNIX Server"):
    sfmc_download = Bash("SFMC Download") 
    s3_upload = Bash("SFMC Upload")

  s3_ingestion_bucket = S3("S3 Ingestion Layer")

  sfmc_server >> sfmc_download >> s3_upload >> s3_ingestion_bucket
