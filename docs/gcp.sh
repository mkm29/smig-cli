# https://medium.com/google-cloud/sigstores-cosign-and-policy-controller-with-gke-and-kms-7bd5b12672ea

################################################################################
##                                    Setup                                   ##
################################################################################

PROJECT_ID=kubula-420821
gcloud config set project ${PROJECT_ID}
REGION=us-east1
ZONE=${REGION}-a

gcloud services enable cloudkms.googleapis.com

################################################################################
##                            Artifact signing                                ##
################################################################################
KEY_RING=cosign
gcloud kms keyrings create ${KEY_RING} \
    --location ${REGION}
KEY_NAME=cosign
gcloud kms keys create ${KEY_NAME} \
    --keyring ${KEY_RING} \
    --location ${REGION} \
    --purpose asymmetric-signing \
    --default-algorithm ec-sign-p256-sha256

gcloud services enable artifactregistry.googleapis.com
REGISTRY_NAME=docker
gcloud artifacts repositories create ${REGISTRY_NAME} \
    --repository-format docker \
    --location ${REGION}

gcloud auth configure-docker ${REGION}-docker.pkg.dev

VERSION=0.1.1
docker build -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}/sigpilot:$VERSION .

SHA=$(docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}/sigpilot:$VERSION | grep digest: | cut -f3 -d" ")

gcloud auth application-default login
cosign generate-key-pair \
    --kms gcpkms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEY_RING}/cryptoKeys/${KEY_NAME}
cosign sign \
    --key gcpkms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEY_RING}/cryptoKeys/${KEY_NAME} \
    ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}/sigpilot@${SHA}

# Verify the signature
cosign verify \
    --key gcpkms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEY_RING}/cryptoKeys/${KEY_NAME} \
    ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}/sigpilot@${SHA}

################################################################################
##           Authentication via Workload Identity Federation                  ##
################################################################################

REPO=mkm29/smig-cli

gcloud iam workload-identity-pools create github-wif-pool --location="global" --project $PROJECT_ID

gcloud iam workload-identity-pools providers create-oidc githubwif \
    --location="global" --workload-identity-pool="github-wif-pool"  \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="attribute.actor=assertion.actor,google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --project $PROJECT_ID

gcloud iam service-accounts create test-wif \
    --display-name="Service account used by WIF POC" \
    --project $PROJECT_ID


ROLES=("roles/cloudkms.signer"
"roles/cloudkms.cryptoKeyEncrypterDecrypter"
"roles/artifactregistry.reader"
"roles/artifactregistry.writer"
)
for ROLE in $ROLES; do
    echo "Adding role $ROLE"
    echo
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:test-wif@$PROJECT_ID.iam.gserviceaccount.com" \
        --role=$ROLE
done

gcloud iam service-accounts add-iam-policy-binding test-wif@$PROJECT_ID.iam.gserviceaccount.com \
    --project=$PROJECT_ID \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/217757495458/locations/global/workloadIdentityPools/github-wif-pool/attribute.repository/$REPO"

# restrict certain branches
# ...
#     --member=principal://iam.googleapis.com/projects/217757495458/locations/global/workloadIdentityPools/github-wif-pool/subject/repo:$REPO:ref:refs/heads/main
