#importing tsv to csv file for real data 
import re 

#reading tsv file in 
with open("estat_nama_10_a64_p5.tsv", 'r') as myfile:
    with open("estat_nama_10_a64_p5.csv", 'w') as csv_file:
        for line in myfile:

            #replace every tab with comma
            fileContent = re.sub("\t", ",", line)

            # writing into csv file
            csv_file.write(fileContent)

#printing out 
print("Success")