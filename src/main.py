import boto3
import os
import json
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain.llms import Bedrock
from langchain.schema import Document
import logging

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def get_opensearch_client():
    """Initialize and return an OpenSearch client"""
    region = os.environ['AWS_REGION']
    service = 'es'
    credentials = boto3.Session().get_credentials()
    awsauth = AWS4Auth(
        credentials.access_key,
        credentials.secret_key,
        region,
        service,
        session_token=credentials.token
    )
    
    opensearch_endpoint = os.environ['OPENSEARCH_ENDPOINT']
    return OpenSearch(
        hosts=[{'host': opensearch_endpoint, 'port': 443}],
        http_auth=awsauth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection
    )

def download_from_s3(bucket, key):
    """Download file from S3"""
    s3 = boto3.client('s3')
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        return response['Body'].read().decode('utf-8')
    except Exception as e:
        logger.error(f"Error downloading from S3: {e}")
        raise

def extract_text(file_content, file_extension):
    """Extract text based on file type"""
    # Add your text extraction logic here
    # For example, use textract for PDFs, DOCX, etc.
    if file_extension.lower() == '.txt':
        return file_content
    else:
        # For other formats, you might use Amazon Textract
        textract = boto3.client('textract')
        response = textract.detect_document_text(
            Document={'Bytes': file_content.encode('utf-8')}
        )
        return ' '.join([item['Text'] for item in response['Blocks'] if item['BlockType'] == 'LINE'])

def generate_summary(text):
    """Generate summary using Bedrock LLM"""
    bedrock_runtime = boto3.client('bedrock-runtime', region_name=os.environ['AWS_REGION'])
    llm = Bedrock(client=bedrock_runtime, model_id="anthropic.claude-v2")
    
    # Split text into chunks if too large
    text_splitter = RecursiveCharacterTextSplitter(
        chunk_size=4000,
        chunk_overlap=200
    )
    docs = text_splitter.create_documents([text])
    
    # Generate summary for each chunk
    summaries = []
    for doc in docs:
        prompt = f"""Please summarize the following text in 3-5 sentences, focusing on the key points:
        
        {doc.page_content}
        
        Summary:"""
        summary = llm(prompt)
        summaries.append(summary)
    
    return ' '.join(summaries)

def index_in_opensearch(doc_id, summary, metadata, opensearch_client):
    """Index the document summary in OpenSearch"""
    index_name = os.environ['OPENSEARCH_INDEX']
    document = {
        'doc_id': doc_id,
        'summary': summary,
        'metadata': metadata,
        'timestamp': datetime.datetime.utcnow().isoformat()
    }
    
    try:
        response = opensearch_client.index(
            index=index_name,
            body=document,
            id=doc_id
        )
        logger.info(f"Successfully indexed document {doc_id}")
        return response
    except Exception as e:
        logger.error(f"Error indexing document: {e}")
        raise

def lambda_handler(event, context):
    try:
        # Get the S3 bucket and key from the event
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = event['Records'][0]['s3']['object']['key']
        file_extension = os.path.splitext(key)[1]
        
        logger.info(f"Processing file: {key} from bucket: {bucket}")
        
        # Download and extract text
        file_content = download_from_s3(bucket, key)
        text = extract_text(file_content, file_extension)
        
        # Generate summary
        summary = generate_summary(text)
        
        # Prepare metadata
        metadata = {
            's3_bucket': bucket,
            's3_key': key,
            'file_type': file_extension
        }
        
        # Store in OpenSearch
        opensearch_client = get_opensearch_client()
        index_in_opensearch(key, summary, metadata, opensearch_client)
        
        return {
            'statusCode': 200,
            'body': json.dumps(f"Successfully processed and summarized {key}")
        }
    except Exception as e:
        logger.error(f"Error in lambda_handler: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error processing file: {str(e)}")
        }