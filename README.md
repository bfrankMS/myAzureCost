# How to setup the Daily Consumption Emailer  
  
# myAzureCost...
[![HitCount](https://hits.dwyl.com/bfrankMS/myAzureCost.svg)](http://hits.dwyl.com/bfrankMS/myAzureCost)  
_...**sends** you a **daily email** with your **azure consumption report**..._  
_...**calculates costs** if **you uploaded a price sheet**..._  
_...uses ARM template for setup, azure automation for daily tasks, sendgrid as 0 cost email solution and storage account to hold data._  
_...**you build** (guided) this in **your subscription**._  


# Result & Screenshots  
In your inbox you'll get a report each day of the usage and the costs (if you upload a price sheet):  
| ![daily email](./pics/email.png) | your **daily cost email** looks similar to this|
|--|--|
| ![consumption report](./pics/ConsumptionCSV.PNG) | **consumption report is attached to email** |
| ![cost report](./pics/CostsCSV.PNG) | some excel cosmetics on the **cost report** |  
  
## The email contains some charts:
| ![7days History](./pics/7DaysHistory.PNG)  | ![Costs Per Region](./pics/CostPerRegion.PNG)  | ![Costs Per RG](./pics/CostPerRG.PNG) |![Costs Per RG](./pics/CostPerCategory.PNG) |
|--|--|--|--|
| **cost email contains history graph**. Azure table is used to hold the data. | Display the **costs per region**. | **Cost per Resource Group** | Cost Per Category |

# The Setup  
[1. Deploy the ARM Template](./SetupChallenges/DeployTheARMTemplate/README.md)  
[2. Create an Azure Run As Account](./SetupChallenges/CreateAzureRunAsAccount/README.md)  
[3. Generate a price sheet](./SetupChallenges/GenerateAPriceSheet/README.md)  
[4. Upload the price sheet.](./SetupChallenges/UploadThePriceSheet/README.md)  
[5. Run a report](./SetupChallenges/RunAReport/README.md)  


# The Solution Architecture  
